// ============================================================================
// FILE 14: 14_DataBackup.swift  (bản 1.26)
// NHIỆM VỤ: Sao lưu / khôi phục data Việt hoá các game ra NGOÀI app (app Tệp: "Trên iPhone" hoặc iCloud Drive).
//
// Vì sao cần: data game nằm trong thư mục Documents/GameProfiles của app. Khi cài bản mới mà iOS coi là
// app khác (ký bằng chứng chỉ / Apple ID khác, đổi bundle ID, hoặc phải xoá app cũ rồi mới cài) thì iOS
// XOÁ LUÔN thư mục của app cũ -> mất data. App không thể tự giữ data qua lần xoá đó, nên data được
// chép thêm một bản ra thư mục do người dùng chọn trong app Tệp (thư mục này không bị xoá theo app).
//
// - Chọn thư mục sao lưu 1 lần -> sau đó mỗi lần nạp data / thêm / xoá / đổi game app tự sao lưu.
// - Sau khi cài bản mới: Thư viện game -> "Khôi phục data" -> chọn lại đúng thư mục đó.
// ============================================================================

import Foundation
import SwiftUI

enum DataBackup {
    static let backupFolderName = "PS5Translator_SaoLuu"
    private static let bookmarkKey = "data_backup_bookmark_v126"
    private static let lastBackupKey = "data_backup_last_v126"
    private static let settingsFile = "cai_dat.json"
    /// Các cài đặt được sao lưu cùng data
    private static let settingKeys = ["active_profile_folder_v102", "profile_stats_v112", "translation_engine_v115",
                                      "skip_paper_text_v117", "psn_user_v102", "show_trash_log_v119"]
    private static let queue = DispatchQueue(label: "ps5translator.backup")
    private static var pending: DispatchWorkItem?

    static var profilesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameProfiles", isDirectory: true)
    }

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static var lastBackupText: String {
        guard let d = UserDefaults.standard.object(forKey: lastBackupKey) as? Date else { return "Chưa sao lưu" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm dd/MM/yyyy"
        return "Sao lưu gần nhất: \(f.string(from: d))"
    }

    /// Số game có file data (.sqlite/.db) trong app
    static func gamesWithData(in root: URL) -> Int {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.filter { name in
            let files = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? []
            return files.contains { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }
        }.count
    }

    // MARK: Thư mục sao lưu (lưu bookmark để lần sau tự ghi, không phải chọn lại)

    private static func resolveBackupParent() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    private static func remember(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    // MARK: Sao lưu

    /// Gọi sau mỗi thay đổi data (gộp nhiều thay đổi liên tiếp thành 1 lần chép, chạy nền)
    static func scheduleAutoBackup() {
        guard isConfigured else { return }
        pending?.cancel()
        let work = DispatchWorkItem { _ = try? backupNow() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Chọn thư mục sao lưu và sao lưu ngay. Trả về số game có data đã sao lưu.
    @discardableResult
    static func setBackupFolder(_ picked: URL) throws -> Int {
        remember(picked)
        return try backupNow(parentOverride: picked)
    }

    @discardableResult
    static func backupNow(parentOverride: URL? = nil) throws -> Int {
        guard let parent = parentOverride ?? resolveBackupParent() else {
            throw TVInstallError("Chưa chọn thư mục sao lưu")
        }
        let fm = FileManager.default
        let source = profilesRoot
        let count = gamesWithData(in: source)

        let secured = parent.startAccessingSecurityScopedResource()
        defer { if secured { parent.stopAccessingSecurityScopedResource() } }

        let target = parent.lastPathComponent == backupFolderName ? parent : parent.appendingPathComponent(backupFolderName, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        // Không ghi đè bản sao lưu có data bằng một app trống (vd. vừa cài lại chưa khôi phục)
        let existing = target.appendingPathComponent("GameProfiles", isDirectory: true)
        if count == 0 && gamesWithData(in: existing) > 0 {
            throw TVInstallError("App chưa có data nên không ghi đè bản sao lưu cũ. Hãy bấm \"Khôi phục data\".")
        }

        // Chép sang thư mục tạm rồi mới thay bản cũ -> lỗi giữa chừng không làm hỏng bản sao lưu
        let temp = target.appendingPathComponent("GameProfiles_dang_chep", isDirectory: true)
        try? fm.removeItem(at: temp)
        if fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: temp)
        } else {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        }
        try? fm.removeItem(at: existing)
        try fm.moveItem(at: temp, to: existing)

        var settings: [String: Any] = [:]
        for key in settingKeys {
            if let v = UserDefaults.standard.object(forKey: key) { settings[key] = v }
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: target.appendingPathComponent(settingsFile), options: .atomic)
        }
        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
        return count
    }

    // MARK: Khôi phục

    /// Tìm thư mục GameProfiles bên trong thư mục người dùng chọn
    private static func findProfiles(in picked: URL) -> (profiles: URL, base: URL)? {
        let fm = FileManager.default
        let candidates = [
            picked.appendingPathComponent(backupFolderName).appendingPathComponent("GameProfiles"),
            picked.appendingPathComponent("GameProfiles"),
            picked,
        ]
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue, gamesWithData(in: c) > 0 {
                return (c, c.deletingLastPathComponent())
            }
        }
        return nil
    }

    /// Chép data từ bản sao lưu vào app (game trùng tên được thay bằng bản sao lưu). Trả về số game có data.
    static func restore(from picked: URL) throws -> Int {
        let fm = FileManager.default
        let secured = picked.startAccessingSecurityScopedResource()
        defer { if secured { picked.stopAccessingSecurityScopedResource() } }

        guard let found = findProfiles(in: picked) else {
            throw TVInstallError("Không thấy data trong thư mục này. Hãy chọn thư mục \"\(backupFolderName)\" (hoặc thư mục chứa nó).")
        }
        let dest = profilesRoot
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var restored = 0
        for name in try fm.contentsOfDirectory(atPath: found.profiles.path) where !name.hasPrefix(".") {
            let src = found.profiles.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let target = dest.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: src, to: target)
            let files = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
            if files.contains(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) { restored += 1 }
        }

        if let data = try? Data(contentsOf: found.base.appendingPathComponent(settingsFile)),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in settingKeys { if let v = settings[key] { UserDefaults.standard.set(v, forKey: key) } }
        }
        // Thư mục đã khôi phục cũng là nơi sao lưu tiếp theo
        remember(found.base.lastPathComponent == backupFolderName ? found.base : picked)
        return restored
    }
}

// MARK: - Nối vào bộ điều phối

extension PipelineCoordinator {
    func chooseBackupFolder(_ url: URL) {
        do {
            let n = try DataBackup.setBackupFolder(url)
            importMessage = "✅ Đã sao lưu data \(n) game vào \"\(url.lastPathComponent)/\(DataBackup.backupFolderName)\". Từ giờ app tự sao lưu mỗi khi data thay đổi."
        } catch {
            importMessage = "⚠️ Sao lưu không thành công: \(error.localizedDescription)"
        }
    }

    func backupDataNow() {
        do {
            let n = try DataBackup.backupNow()
            importMessage = "✅ Đã sao lưu data \(n) game."
        } catch {
            importMessage = "⚠️ \(error.localizedDescription)"
        }
    }

    func restoreData(from url: URL) {
        do {
            let n = try DataBackup.restore(from: url)
            refreshGameProfileFolders()
            if let name = UserDefaults.standard.string(forKey: "active_profile_folder_v102"),
               gameProfiles.contains(where: { $0.folderName == name }) {
                activateGameProfileFolder(folderName: name)
            }
            importMessage = "✅ Đã khôi phục data \(n) game."
        } catch {
            importMessage = "⚠️ Khôi phục không thành công: \(error.localizedDescription)"
        }
    }
}
