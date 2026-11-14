// ============================================================================
// FILE 12: 12_ModernUI.swift
// PHIÊN BẢN: PS5Translator 1.22
//
// GIAO DIỆN MỚI (lấy cảm hứng iOS 27 – kính mờ, đen mờ & trắng, bo tròn):
// - Bộ màu / nền / kiểu kính dùng chung (MQTheme, .mqGlass, .mqPill)
// - Thanh tab dưới: Trang chủ · Game · Thư viện Game
// - Log quét chữ cỡ lớn: DATA (khớp data Việt hoá) / AI (dịch AI) / RÁC (bỏ qua, có lý do)
// - Tab Game (game đang chơi), Cài đặt (nút bánh răng), Logo MQ
// ============================================================================

import SwiftUI

// MARK: - Bộ màu & nền

enum MQTheme {
    static let bgTop = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let bgBottom = Color(red: 0.025, green: 0.025, blue: 0.03)
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let pearl = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.40)
    static let hairline = Color.white.opacity(0.10)
    static let rowFill = Color.black.opacity(0.32)
    /// 1.21: màu công tắc khi bật (xám bạc) để nút gạt trắng luôn nhìn thấy
    static let toggleOn = Color(white: 0.52)
}

struct MQBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [MQTheme.bgTop, MQTheme.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.09), .clear], center: .topTrailing, startRadius: 10, endRadius: 440)
            RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .bottomLeading, startRadius: 10, endRadius: 400)
        }
        .ignoresSafeArea()
    }
}

/// Thẻ kính mờ bo tròn
struct MQGlass: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(MQTheme.hairline, lineWidth: 1))
    }
}

/// Nút viên thuốc: chọn = trắng ngọc trai chữ đen, không chọn = kính mờ chữ trắng
struct MQPill: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        content
            .foregroundColor(selected ? MQTheme.ink : .white)
            .background(
                Group {
                    if selected {
                        Capsule().fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Color.white.opacity(0.14), radius: 8, x: 0, y: 3)
                    } else {
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(MQTheme.hairline, lineWidth: 1))
                    }
                }
            )
            .contentShape(Capsule())
    }
}

extension View {
    func mqGlass(_ radius: CGFloat = 24) -> some View { modifier(MQGlass(radius: radius)) }
    func mqPill(_ selected: Bool) -> some View { modifier(MQPill(selected: selected)) }
}

/// Theo dõi trực tiếp 1 đối tượng con (videoMgr / server) để phần giao diện đó tự cập nhật
struct MQObserve<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    let content: (Object) -> Content

    init(_ object: Object, @ViewBuilder content: @escaping (Object) -> Content) {
        self._object = ObservedObject(wrappedValue: object)
        self.content = content
    }

    var body: some View { content(object) }
}

// MARK: - Logo MQ (app_logo.png trong app, không có thì dùng biểu tượng hệ thống)

struct MQLogoView: View {
    var height: CGFloat = 44

    var body: some View {
        if let ui = UIImage(named: "app_logo") {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .shadow(color: Color.white.opacity(0.15), radius: 8)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: height * 0.55, weight: .bold))
                Text("MQ")
                    .font(.system(size: height * 0.55, weight: .black))
                    .italic()
            }
            .foregroundColor(.white)
            .frame(height: height)
        }
    }
}

// MARK: - Thanh tab dưới

enum MainSection: String, CaseIterable, Identifiable {
    case home, game, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Trang chủ"
        case .game: return "Game"
        case .library: return "Thư viện Game"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .game: return "gamecontroller.fill"
        case .library: return "books.vertical.fill"
        }
    }
}

struct MQTabBar: View {
    @Binding var selection: MainSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainSection.allCases) { s in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = s }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: s.icon)
                            .font(.system(size: 19, weight: .semibold))
                        Text(s.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(selection == s ? .white : MQTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        Group {
                            if selection == s {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                            }
                        }
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(MQTheme.hairline, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - Log quét chữ

extension ScanLogKind {
    var label: String {
        switch self {
        case .data: return "DATA"
        case .ai: return "AI"
        case .pending: return "AI…"
        case .missing: return "CHƯA DỊCH"
        case .trash: return "RÁC"
        }
    }

    var icon: String {
        switch self {
        case .data: return "checkmark.seal.fill"
        case .ai: return "sparkles"
        case .pending: return "hourglass"
        case .missing: return "questionmark.circle"
        case .trash: return "nosign"
        }
    }

    var barColor: Color {
        switch self {
        case .data: return MQTheme.pearl
        case .ai: return Color.white.opacity(0.55)
        case .pending: return Color.white.opacity(0.3)
        case .missing: return Color.white.opacity(0.3)
        case .trash: return Color.white.opacity(0.15)
        }
    }
}

struct ScanKindChip: View {
    let kind: ScanLogKind
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 9, weight: .bold))
            Text(count.map { "\(kind.label) \($0)" } ?? kind.label)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(foreground)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }

    private var foreground: Color {
        switch kind {
        case .data: return MQTheme.ink
        case .ai, .missing: return .white
        case .pending, .trash: return MQTheme.tertiary
        }
    }

    private var fill: Color {
        switch kind {
        case .data: return MQTheme.pearl
        case .missing: return Color.white.opacity(0.14)
        case .trash: return Color.white.opacity(0.06)
        case .ai, .pending: return .clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .ai: return Color.white.opacity(0.55)
        case .pending: return Color.white.opacity(0.25)
        default: return .clear
        }
    }
}

struct ScanLogRow: View {
    let entry: ScanLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                ScanKindChip(kind: entry.kind)
                Spacer()
                Text(Self.timeFormatter.string(from: entry.time))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(MQTheme.tertiary)
            }
            Text(entry.source)
                .font(.system(size: 13))
                .foregroundColor(entry.kind == .trash ? MQTheme.tertiary : MQTheme.secondary)
                .strikethrough(entry.kind == .trash)
                .lineLimit(3)
            if let vi = entry.translation {
                Text(vi)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = entry.note {
                Text(note)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundColor(MQTheme.tertiary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MQTheme.rowFill))
        .overlay(
            Capsule()
                .fill(entry.kind.barColor)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 3),
            alignment: .leading
        )
        .opacity(entry.kind == .trash ? 0.75 : 1)
    }
}

/// Khung Log quét chữ trên Trang chủ (thay dòng "Quét (0 vùng)…" cũ)
struct ScanLogPanel: View {
    @ObservedObject var coord: PipelineCoordinator
    var maxRows: Int = 5
    var onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15, weight: .bold))
                Text("Log quét chữ")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                MQObserve(coord.videoMgr) { vm in
                    Text(vm.isReceivingRealPS5Video || vm.currentFullFrame != nil ? "● LIVE" : "CHỜ HÌNH")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundColor(vm.isReceivingRealPS5Video || vm.currentFullFrame != nil ? .white : MQTheme.tertiary)
                }
                Spacer(minLength: 4)
                Button(action: { coord.triggerTVTestSentence() }) {
                    HStack(spacing: 5) {
                        Image(systemName: coord.isShowingTVTestSentence ? "checkmark" : "tv")
                            .font(.system(size: 12, weight: .bold))
                        Text("Test phụ đề TV")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .mqPill(true)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white)

            HStack(spacing: 6) {
                ScanKindChip(kind: .data, count: coord.logCounts[.data] ?? 0)
                ScanKindChip(kind: .ai, count: coord.logCounts[.ai] ?? 0)
                ScanKindChip(kind: .trash, count: coord.logCounts[.trash] ?? 0)
                Spacer()
                if !coord.scanLog.isEmpty {
                    Button(action: { coord.clearScanLog() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(MQTheme.secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if coord.isShowingTVTestSentence {
                Label("TV Test: \(TranslatorV102Config.tvTestSentence)", systemImage: "tv.badge.wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.12)))
            }

            let rows = Array(coord.visibleScanLog.prefix(maxRows))
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 22))
                    Text(coord.lastRecognizedEnglish)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundColor(MQTheme.tertiary)
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MQTheme.rowFill))
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { entry in
                        ScanLogRow(entry: entry)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: rows.map { $0.id })
            }

            if coord.visibleScanLog.count > maxRows {
                Button(action: onShowAll) {
                    HStack {
                        Text("Xem toàn bộ log (\(coord.visibleScanLog.count))")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(MQTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .mqGlass(26)
        .padding(.horizontal, 14)
    }
}

/// Toàn bộ log / Lịch sử câu đã dịch (chia sẻ được)
struct ScanLogHistorySheet: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    Toggle(isOn: $coord.showTrashInLog) {
                        Text("Hiện chữ rác bị bỏ qua")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .tint(MQTheme.toggleOn)
                    .padding(12)
                    .mqGlass(18)

                    if coord.visibleScanLog.isEmpty {
                        Text("Chưa có câu nào. Mở Trang chủ và kết nối PS5 để bắt đầu quét.")
                            .font(.system(size: 13))
                            .foregroundColor(MQTheme.tertiary)
                            .padding(.top, 30)
                    }
                    ForEach(coord.visibleScanLog) { entry in
                        ScanLogRow(entry: entry)
                    }
                }
                .padding(16)
            }
            .background(MQBackground())
            .navigationTitle("Lịch sử câu đã dịch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Xoá log") { coord.clearScanLog() }
                        .disabled(coord.scanLog.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        ShareLink(item: coord.scanLogExportText()) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button("Xong") { dismiss() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

// MARK: - Tab Game (game đang chơi)

extension TranslationEngineMode {
    var shortTitle: String {
        switch self {
        case .appleThenGoogle, .appleOnly, .googleOnly: return "Data + AI"
        case .offline: return "Chỉ data"
        }
    }
}

struct GamePlayingView: View {
    @ObservedObject var coord: PipelineCoordinator
    var onPlay: () -> Void
    var onChangeGame: () -> Void

    @State private var showNames = false
    @State private var showHistory = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Đang chơi")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)

                gameCard

                if let msg = coord.importMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(MQTheme.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mqGlass(16)
                }

                sectionTitle("Bộ dịch cho game này")
                enginePicker

                sectionTitle("Thiết lập")
                settingsList
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showNames) {
            ProperNamesSheet(names: coord.properNames, gameName: coord.activeProfileFolderName)
        }
        .sheet(isPresented: $showHistory) {
            ScanLogHistorySheet(coord: coord)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundColor(MQTheme.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }

    private var activeProfile: GameProfileFolder? {
        coord.gameProfiles.first { $0.folderName == coord.activeProfileFolderName }
    }

    private var gameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1.22: ảnh bìa lớn hiện rõ (chạm để đổi ảnh), tên game nằm bên dưới
            Group {
                if let p = activeProfile {
                    CoverPhotoPicker(name: p.folderName, folderURL: p.folderURL) {
                        GameCoverBanner(name: p.folderName, folderURL: p.folderURL)
                    }
                    .buttonStyle(.plain)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.24), Color(white: 0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        GameMonogram(name: coord.activeProfileFolderName, size: 96)
                    }
                    .aspectRatio(1.2, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(coord.activeProfileFolderName)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text("Đang chơi")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(MQTheme.pearl))
                        .foregroundColor(MQTheme.ink)
                }
                Text(coord.databaseReport)
                    .font(.system(size: 12))
                    .foregroundColor(MQTheme.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                statTile(coord.loadedLineCount.formatted(), "câu trong data")
                statTile("\(coord.logCounts[.data] ?? 0)", "khớp data")
                statTile("\(coord.logCounts[.ai] ?? 0)", "dịch bằng AI")
            }

            HStack(spacing: 8) {
                Button(action: onPlay) {
                    Label("Vào chơi", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .mqPill(true)
                }
                .buttonStyle(.plain)
                Button(action: onChangeGame) {
                    Label("Đổi game", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .mqPill(false)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .mqGlass(26)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(MQTheme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MQTheme.rowFill))
    }

    /// 1.21: chỉ dùng chế độ "Tất cả" (đã bỏ nút Apple AI / Google / Chỉ data)
    private var enginePicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(MQTheme.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MQTheme.pearl))
            VStack(alignment: .leading, spacing: 3) {
                Text("Data Việt hoá → AI iPhone (không dùng Google)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(OnDeviceAITranslator.shared.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(MQTheme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .mqGlass(22)
    }

    private var settingsList: some View {
        VStack(spacing: 0) {
            settingRow(icon: "book.closed", title: "Danh sách tên riêng",
                       subtitle: "\(coord.properNames.count) tên · giữ nguyên khi dịch") {
                Image(systemName: "chevron.right").foregroundColor(MQTheme.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { showNames = true }
            divider
            settingRow(icon: "line.3.horizontal.decrease", title: "Bộ lọc chữ rác",
                       subtitle: "Hiện chữ bị bỏ qua (nút HUD, ký tự lạ, số đếm) trong log") {
                Toggle("", isOn: $coord.showTrashInLog).labelsHidden().tint(MQTheme.toggleOn)
            }
            divider
            settingRow(icon: "doc.text", title: "Không dịch chữ trên giấy",
                       subtitle: "Bỏ qua thư, ghi chú, biển báo (mực tối trên nền sáng)") {
                Toggle("", isOn: $coord.skipPaperText).labelsHidden().tint(MQTheme.toggleOn)
            }
            divider
            settingRow(icon: "clock.arrow.circlepath", title: "Lịch sử câu đã dịch",
                       subtitle: "\(coord.scanLog.count) dòng · xuất log phiên chơi") {
                Image(systemName: "chevron.right").foregroundColor(MQTheme.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { showHistory = true }
        }
        .padding(.horizontal, 14)
        .mqGlass(24)
    }

    private var divider: some View {
        Rectangle().fill(MQTheme.hairline).frame(height: 1)
    }

    private func settingRow<Trailing: View>(icon: String, title: String, subtitle: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
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
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(MQTheme.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 11)
    }
}

struct ProperNamesSheet: View {
    let names: [String]
    let gameName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Các tên này được giữ nguyên khi dịch bằng AI (lấy từ data Việt hoá của \(gameName)).")
                        .font(.system(size: 13))
                        .foregroundColor(MQTheme.secondary)
                    if names.isEmpty {
                        Text("Data của game này chưa có danh sách tên riêng.")
                            .font(.system(size: 13))
                            .foregroundColor(MQTheme.tertiary)
                            .padding(.top, 20)
                    }
                    ForEach(names, id: \.self) { n in
                        Text(n)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MQTheme.rowFill))
                    }
                }
                .padding(16)
            }
            .background(MQBackground())
            .navigationTitle("Tên riêng (\(names.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

// MARK: - Cài đặt (nút bánh răng)

struct MQSettingsSheet: View {
    @ObservedObject var coord: PipelineCoordinator
    @ObservedObject var videoMgr: VideoSourceManager
    @ObservedObject var server: TVWebSocketServer
    @Environment(\.dismiss) private var dismiss
    @State private var showTVInstaller = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("TV Samsung") {
                        infoRow("IP nhập vào TV", "\(server.ipAddress):\(String(AppConfig.webSocketPort))", mono: true)
                        infoRow("TV đang kết nối", "\(server.connectedCount)")
                        Button(action: {
                            coord.triggerTVTestSentence()
                            dismiss()
                        }) {
                            Label("Gửi câu test lên TV", systemImage: "tv.badge.wifi")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .mqPill(true)
                        }
                        .buttonStyle(.plain)
                        Button(action: { showTVInstaller = true }) {
                            Label("Cài / cập nhật app lên TV Samsung", systemImage: "square.and.arrow.down.on.square")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .mqPill(false)
                        }
                        .buttonStyle(.plain)
                    }

                    group("Kết nối PS5") {
                        Toggle(isOn: $videoMgr.autoReconnectEnabled) {
                            toggleLabel("Tự kết nối lại", "Khi mở app, khi quay lại app, hoặc khi PS5 ngắt phiên")
                        }
                        .tint(MQTheme.toggleOn)
                        Toggle(isOn: $videoMgr.keepAliveInBackground) {
                            toggleLabel("Giữ kết nối khi thoát app ra ngoài", "App tiếp tục chạy nền (tốn pin hơn)")
                        }
                        .tint(MQTheme.toggleOn)
                        Toggle(isOn: $videoMgr.preventAutoLock) {
                            toggleLabel("Không tự khoá màn hình", "Màn hình luôn sáng khi đang kết nối PS5, tránh mất phiên Remote Play")
                        }
                        .tint(MQTheme.toggleOn)
                    }

                    group("Data Việt hoá nhận được") {
                        Text("• .sqlite / .db có cột tiếng Anh + cột tiếng Việt (vd: en, vi)\n• .csv / .tsv có dòng tiêu đề en,vi (tuỳ chọn: speaker)\n• .txt mỗi dòng: Câu tiếng Anh ||| Câu tiếng Việt")
                            .font(.system(size: 13))
                            .foregroundColor(MQTheme.secondary)
                    }

                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            MQLogoView(height: 54)
                            Text(TranslatorV102Config.appVersionName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(MQTheme.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .background(MQBackground())
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
            .sheet(isPresented: $showTVInstaller) {
                TVInstallerView()
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundColor(MQTheme.tertiary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mqGlass(24)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(MQTheme.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(size: 15, weight: .bold, design: .monospaced) : .system(size: 15, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func toggleLabel(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Text(sub).font(.system(size: 12)).foregroundColor(MQTheme.tertiary)
        }
    }
}
