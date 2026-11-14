// ============================================================================
// FILE 9: 9_GameLibraryView.swift
// PHIÊN BẢN: PS5Translator 1.21 (tab Thư viện Game, ảnh bìa game)
//
// THƯ VIỆN GAME (thay màn hình "Quản lý Hồ sơ Game" cũ):
// - Thẻ game đang dùng: tên, số câu Việt hoá dùng được, tình trạng data, bộ dịch AI.
// - Lưới danh sách game: chạm để chọn game, menu "..." để nạp data / xoá.
// - "Thêm game mới": nhập tên + chọn file data Việt hoá trong 1 màn hình.
// - Nhập data từ .sqlite / .db, hoặc .csv / .tsv (cột en, vi), hoặc .txt (Anh ||| Việt)
//   -> tự chuyển sang cấu trúc chuẩn translations_v2.
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import SQLite3

// MARK: - Chuyển CSV / TXT thành SQLite chuẩn

enum DataImporter {
    enum ImportError: LocalizedError {
        case unreadable, noPairs, columnsNotFound([String]), sqlite(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Không đọc được file (cần mã hoá UTF-8)."
            case .noPairs: return "Không tìm thấy cặp câu Anh → Việt nào trong file."
            case .columnsNotFound(let cols): return "Không thấy cột tiếng Anh / tiếng Việt. Cột hiện có: \(cols.joined(separator: ", "))"
            case .sqlite(let m): return "Lỗi tạo SQLite: \(m)"
            }
        }
    }

    static let enAliases = ["en", "english", "en_raw", "original_text", "original", "source", "source_text", "text_raw", "text_en"]
    static let viAliases = ["vi", "vietnamese", "vi_text", "translated_text", "translation", "target", "target_text", "text_vi"]

    /// Đọc file văn bản thành danh sách cặp (en, vi, speaker)
    static func readPairs(from url: URL) throws -> [(en: String, vi: String, speaker: String?)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable }
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        let ext = url.pathExtension.lowercased()

        if ext == "txt" {
            var pairs: [(en: String, vi: String, speaker: String?)] = []
            for line in text.components(separatedBy: .newlines) where line.contains("|||") {
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 2 else { continue }
                pairs.append((en: parts[0].trimmingCharacters(in: .whitespaces), vi: parts[1].trimmingCharacters(in: .whitespaces), speaker: nil))
            }
            if pairs.isEmpty { throw ImportError.noPairs }
            return pairs
        }

        let delimiter: Character = (ext == "tsv" || ext == "tab") ? "\t" : ","
        let rows = parseCSV(text, delimiter: delimiter)
        guard let header = rows.first else { throw ImportError.noPairs }
        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard let enIdx = enAliases.compactMap({ lower.firstIndex(of: $0) }).first,
              let viIdx = viAliases.compactMap({ lower.firstIndex(of: $0) }).first else {
            throw ImportError.columnsNotFound(header)
        }
        let spkIdx = lower.firstIndex(of: "speaker")
        var pairs: [(en: String, vi: String, speaker: String?)] = []
        for row in rows.dropFirst() where row.count > max(enIdx, viIdx) {
            let spk = spkIdx.flatMap { $0 < row.count ? row[$0] : nil }
            pairs.append((en: row[enIdx], vi: row[viIdx], speaker: (spk?.isEmpty ?? true) ? nil : spk))
        }
        if pairs.isEmpty { throw ImportError.noPairs }
        return pairs
    }

    /// Bộ đọc CSV chuẩn RFC 4180 (ô có dấu ngoặc kép, xuống dòng trong ô)
    static func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    /// Ghi các cặp câu ra SQLite chuẩn translations_v2. Trả về số cặp đã ghi.
    @discardableResult
    static func writeSQLite(pairs: [(en: String, vi: String, speaker: String?)], to dest: URL) throws -> Int {
        try? FileManager.default.removeItem(at: dest)
        var db: OpaquePointer?
        guard sqlite3_open(dest.path, &db) == SQLITE_OK, let conn = db else {
            throw ImportError.sqlite("không mở được file")
        }
        defer { sqlite3_close(conn) }
        let schema = """
        CREATE TABLE translations_v2(id INTEGER PRIMARY KEY, en TEXT NOT NULL, vi TEXT NOT NULL, en_norm TEXT NOT NULL,
                                     speaker TEXT, category TEXT, string_key TEXT);
        CREATE INDEX idx_translations_v2_norm ON translations_v2(en_norm);
        CREATE TABLE glossary(term TEXT PRIMARY KEY, vi TEXT, keep_original INTEGER DEFAULT 1, kind TEXT);
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('format','ps5translator-v2');
        BEGIN TRANSACTION;
        """
        guard sqlite3_exec(conn, schema, nil, nil, nil) == SQLITE_OK else {
            throw ImportError.sqlite(String(cString: sqlite3_errmsg(conn)))
        }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO translations_v2(en, vi, en_norm, speaker) VALUES (?,?,?,?)"
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ImportError.sqlite(String(cString: sqlite3_errmsg(conn)))
        }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var count = 0
        var seen = Set<String>()
        for p in pairs {
            let en = p.en.trimmingCharacters(in: .whitespacesAndNewlines)
            let vi = p.vi.trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = TranslationMemory.normalize(en)
            guard !norm.isEmpty, !vi.isEmpty, norm != TranslationMemory.normalize(vi) else { continue }
            guard seen.insert(norm + "\u{1}" + vi).inserted else { continue }
            sqlite3_reset(s)
            sqlite3_bind_text(s, 1, en, -1, transient)
            sqlite3_bind_text(s, 2, vi, -1, transient)
            sqlite3_bind_text(s, 3, norm, -1, transient)
            if let spk = p.speaker { sqlite3_bind_text(s, 4, spk, -1, transient) } else { sqlite3_bind_null(s, 4) }
            if sqlite3_step(s) == SQLITE_DONE { count += 1 }
        }
        sqlite3_exec(conn, "COMMIT;", nil, nil, nil)
        if count == 0 { throw ImportError.noPairs }
        return count
    }
}

// MARK: - Thư viện game (1.19: tab "Thư viện Game" ở thanh tab dưới)

struct GameLibraryView: View {
    @ObservedObject var coord: PipelineCoordinator
    /// Gọi sau khi chọn game -> chuyển sang tab Game
    var onPicked: (() -> Void)? = nil

    @State private var showAddGame = false
    @State private var importTargetFolder: String = ""
    @State private var showImporter = false
    @State private var confirmDelete: GameProfileFolder?
    @State private var searchText = ""
    /// 1.26: một fileImporter dùng chung cho nạp data / chọn thư mục sao lưu / khôi phục
    @State private var pickMode: PickMode = .data
    private enum PickMode { case data, backupFolder, restoreFolder }

    private var filteredProfiles: [GameProfileFolder] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return coord.gameProfiles }
        return coord.gameProfiles.filter { $0.folderName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Thư viện Game")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { showAddGame = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 44, height: 44)
                            .mqPill(true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(MQTheme.tertiary)
                    TextField("Tìm game…", text: $searchText)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().stroke(MQTheme.hairline, lineWidth: 1))

                if let msg = coord.importMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(MQTheme.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mqGlass(16)
                }

                sectionTitle("Đã cài data (\(coord.gameProfiles.count))")
                if filteredProfiles.isEmpty {
                    Text(coord.gameProfiles.isEmpty ? "Chưa có game nào. Bấm + để thêm game và nạp data Việt hoá." : "Không tìm thấy game.")
                        .font(.system(size: 13))
                        .foregroundColor(MQTheme.tertiary)
                        .padding(.horizontal, 6)
                }
                ForEach(filteredProfiles) { profile in
                    gameRow(profile)
                }

                sectionTitle("Thêm data")
                VStack(spacing: 0) {
                    actionRow(icon: "square.and.arrow.down", title: "Nạp file data cho \(coord.activeProfileFolderName)",
                              subtitle: ".sqlite, .db, .csv, .tsv, .txt · từ Tệp / iCloud Drive") {
                        importTargetFolder = coord.activeProfileFolderName
                        pickMode = .data
                        showImporter = true
                    }
                    Rectangle().fill(MQTheme.hairline).frame(height: 1)
                    actionRow(icon: "plus", title: "Thêm game mới", subtitle: "Tên game + data Việt hoá (chưa có data thì dịch bằng AI)") {
                        showAddGame = true
                    }
                }
                .padding(.horizontal, 14)
                .mqGlass(24)

                // 1.26: sao lưu / khôi phục data game (giữ data khi cài bản app mới)
                sectionTitle("Sao lưu data")
                VStack(spacing: 0) {
                    actionRow(icon: "externaldrive.badge.icloud",
                              title: DataBackup.isConfigured ? "Sao lưu ngay" : "Chọn thư mục sao lưu",
                              subtitle: DataBackup.isConfigured ? "Tự sao lưu khi data thay đổi · \(DataBackup.lastBackupText)"
                                                                : "Chọn 1 thư mục trong Tệp (Trên iPhone / iCloud Drive), app sẽ tự sao lưu vào đó") {
                        if DataBackup.isConfigured { coord.backupDataNow() }
                        else { pickMode = .backupFolder; showImporter = true }
                    }
                    Rectangle().fill(MQTheme.hairline).frame(height: 1)
                    actionRow(icon: "arrow.counterclockwise", title: "Khôi phục data",
                              subtitle: "Sau khi cài bản app mới: chọn thư mục \"\(DataBackup.backupFolderName)\" đã sao lưu") {
                        pickMode = .restoreFolder
                        showImporter = true
                    }
                    if DataBackup.isConfigured {
                        Rectangle().fill(MQTheme.hairline).frame(height: 1)
                        actionRow(icon: "folder", title: "Đổi thư mục sao lưu", subtitle: "Chọn nơi khác để lưu bản sao") {
                            pickMode = .backupFolder
                            showImporter = true
                        }
                    }
                }
                .padding(.horizontal, 14)
                .mqGlass(24)

                Text("Tạo data từ file game: dùng tools/vietsub_db_tool.py trên máy tính.")
                    .font(.system(size: 12))
                    .foregroundColor(MQTheme.tertiary)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showAddGame) {
            AddGameSheet(coord: coord)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: pickMode == .data ? DataTypes.allowed : [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                switch pickMode {
                case .data: coord.importDataIntoProfileFolder(folderName: importTargetFolder, sourceURL: url)
                case .backupFolder: coord.chooseBackupFolder(url)
                case .restoreFolder: coord.restoreData(from: url)
                }
            }
            pickMode = .data
        }
        .alert(item: $confirmDelete) { profile in
            Alert(
                title: Text("Xoá game \"\(profile.folderName)\"?"),
                message: Text("Data Việt hoá của game này cũng bị xoá khỏi app."),
                primaryButton: .destructive(Text("Xoá")) { coord.deleteGameProfileFolder(folderName: profile.folderName) },
                secondaryButton: .cancel(Text("Huỷ"))
            )
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundColor(MQTheme.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
    }

    private func pick(_ profile: GameProfileFolder) {
        if coord.activeProfileFolderName != profile.folderName {
            coord.activateGameProfileFolder(folderName: profile.folderName)
        }
        onPicked?()
    }

    private func gameRow(_ profile: GameProfileFolder) -> some View {
        let isActive = coord.activeProfileFolderName == profile.folderName
        let stat = coord.profileStats[profile.folderName]
        let hasFile = profile.sqliteFileName.hasSuffix(".sqlite") || profile.sqliteFileName.hasSuffix(".db")
        let subtitle: String
        if !hasFile {
            subtitle = "Chưa có data · dịch bằng AI"
        } else if let n = stat {
            subtitle = n > 0 ? "\(n.formatted()) câu Việt hoá" : "Chưa có câu Việt hoá · dịch bằng AI"
        } else {
            subtitle = "Có data · chọn để kiểm tra"
        }
        return HStack(spacing: 12) {
            GameCoverView(name: profile.folderName, folderURL: profile.folderURL, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.folderName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(MQTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                Button(action: {
                    importTargetFolder = profile.folderName
                    showImporter = true
                }) {
                    Label(hasFile ? "Thay data Việt hoá" : "Nạp data Việt hoá", systemImage: "square.and.arrow.down")
                }
                CoverPhotoPicker(name: profile.folderName, folderURL: profile.folderURL) {
                    Label("Chọn ảnh bìa từ Ảnh", systemImage: "photo")
                }
                Button(action: {
                    GameCoverStore.shared.reloadCover(name: profile.folderName, folderURL: profile.folderURL)
                }) {
                    Label("Tải lại ảnh bìa từ PlayStation Store", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive, action: { confirmDelete = profile }) {
                    Label("Xoá game", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MQTheme.secondary)
                    .frame(width: 30, height: 30)
            }
            Button(action: { pick(profile) }) {
                Text(isActive ? "Đang chơi" : "Chọn")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .mqPill(isActive)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .mqGlass(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.55 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { pick(profile) }
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(MQTheme.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .foregroundColor(MQTheme.tertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum DataTypes {
    static var allowed: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .data, .item]
        if let sqlite = UTType(filenameExtension: "sqlite") { types.insert(sqlite, at: 0) }
        if let db = UTType(filenameExtension: "db") { types.insert(db, at: 0) }
        return types
    }
}

/// Biểu tượng chữ cái đầu tên game (màu theo tên)
struct GameMonogram: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        // 1.19: ô xám đơn sắc (đen mờ & trắng), độ sáng khác nhau theo tên game
        let shade = Double(name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360.0
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(white: 0.24 + shade * 0.16), Color(white: 0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

// MARK: - Thêm game mới

struct AddGameSheet: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var name = ""
    @State private var pickedFile: URL?
    @State private var showImporter = false

    private let accent = Color.white.opacity(0.6)

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tên game").font(.subheadline.bold())
                    TextField("VD: Until Dawn, God of War Ragnarök", text: $name)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Data Việt hoá (không bắt buộc)").font(.subheadline.bold())
                    Button(action: { showImporter = true }) {
                        HStack {
                            Image(systemName: pickedFile == nil ? "doc.badge.plus" : "doc.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pickedFile?.lastPathComponent ?? "Chọn file data")
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(".sqlite, .db, .csv, .tsv hoặc .txt (Anh ||| Việt)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundColor(accent))
                    }
                    .buttonStyle(.plain)
                    Text("Chưa có data? Vẫn tạo được game: app sẽ dịch bằng AI và bạn nạp data sau.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button(action: create) {
                    Text(pickedFile == nil ? "Tạo game" : "Tạo game & nạp data")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.12) : MQTheme.pearl)
                        .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? MQTheme.tertiary : MQTheme.ink)
                        .clipShape(Capsule())
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(18)
            .navigationTitle("Thêm game mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Huỷ") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: DataTypes.allowed, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { pickedFile = urls.first }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        coord.createNewGameProfileFolder(folderName: clean)
        if let file = pickedFile {
            coord.importDataIntoProfileFolder(folderName: clean, sourceURL: file)
        } else {
            coord.activateGameProfileFolder(folderName: clean)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
