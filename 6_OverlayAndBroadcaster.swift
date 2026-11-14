// ============================================================================
// FILE 6A: 6_OverlayAndBroadcaster.swift (TÁCH TỪ FILE 6 - PHẦN 1/2)
// PHIÊN BẢN: PS5Translator 1.02
// NHIỆM VỤ:
// 1. Cấu hình phiên bản (TranslatorV102Config) & cấu trúc vùng chữ (V102OCRTextRegion).
// 2. Lõi quét OCR đa vùng & gom cụm không gian (V102OCREngine).
// 3. Lõi đọc cơ sở dữ liệu Việt hoá SQLite (V102SQLiteTranslator).
// 4. Bộ dịch AI dự phòng đa vùng (AppleIntelligenceFallbackEngine).
// 5. Máy chủ WebSocket phát phụ đề sang TV Samsung cổng 8080 (TVWebSocketServer).
// 6. Bộ điều phối trung tâm đồng bộ vị trí & thời gian thực (PipelineCoordinator).
// ============================================================================

import SwiftUI
import Network
import Combine
import WebKit
import UniformTypeIdentifiers
import Vision
import SQLite3

// ============================================================================
// 1. THÔNG SỐ CẤU HÌNH PHIÊN BẢN PS5TRANSLATOR 1.02 (Đặt ở đầu file)
// ============================================================================
struct TranslatorV102Config {
    static let appVersionName = "PS5Translator 1.28"
    static let tvTestSentence = "phụ đề tiếng Việt như thế này"
    static let defaultScanFPS: Double = 6.0
    static let minScanFPS: Double = 1.0
    static let maxScanFPS: Double = 15.0

    // Độ đậm phông nền đen mờ che chữ tiếng Anh gốc (0.94 = che kín chữ gốc bên dưới)
    static let subtitleMaskBlackOpacity: Double = 0.94

    // ĐÃ SỬA LỖI 4174 REDIRECT URI MISMATCH:
    // Cặp Client ID 09515159-7237-4370-9b40-3806e67c0891 của Sony bắt buộc đi kèm
    // redirect_uri = com.scee.psxandroid.scecompcall://redirect
    static let sonyOAuthLoginURL = "https://ca.account.sony.com/api/authz/v3/oauth/authorize?access_type=offline&client_id=09515159-7237-4370-9b40-3806e67c0891&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&response_type=code&scope=psn:mobile.v2.core%20psn:clientapp"
    static let sonyOAuthRedirectPrefix = "com.scee.psxandroid.scecompcall://redirect"
    static let sonyOAuthRedirectEncoded = "com.scee.psxandroid.scecompcall%3A%2F%2Fredirect"
    static let sonyOAuthTokenURL = "https://ca.account.sony.com/api/authz/v3/oauth/token"
    static let sonyBasicAuthHeader = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="
}

// Khối văn bản OCR kèm toạ độ gốc chính xác và số dòng
struct V102OCRTextRegion {
    var rawText: String
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    var lineCount: Int
}

struct GameProfileFolder: Identifiable, Equatable {
    var id: String { folderName }
    let folderName: String
    let sqliteFileName: String
    let fullSQLiteURL: URL
}

// ============================================================================
// 2. LÕI QUÉT CHỮ ĐA VÙNG & GOM CỤM KHÔNG GIAN (SPATIAL REGION CLUSTERER V1.02)
// ============================================================================
final class V102OCREngine {
    private let queue = DispatchQueue(label: "ps5.v102.ocr.queue", qos: .userInteractive)

    func recognizeMultiRegions(in cgImage: CGImage, completion: @escaping ([V102OCRTextRegion]) -> Void) {
        queue.async {
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    completion([])
                    return
                }

                var rawLines: [V102OCRTextRegion] = []
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let text = top.string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let bbox = obs.boundingBox
                    let convertedY = 1.0 - bbox.origin.y - bbox.size.height
                    rawLines.append(
                        V102OCRTextRegion(
                            rawText: text,
                            x: max(0.0, min(1.0, bbox.origin.x)),
                            y: max(0.0, min(1.0, convertedY)),
                            w: max(0.02, min(1.0, bbox.size.width)),
                            h: max(0.015, min(1.0, bbox.size.height)),
                            lineCount: 1
                        )
                    )
                }

                let clustered = Self.clusterAdjacentLinesIntoRegions(lines: rawLines)
                completion(clustered)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                completion([])
            }
        }
    }

    private static func clusterAdjacentLinesIntoRegions(lines: [V102OCRTextRegion]) -> [V102OCRTextRegion] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted {
            if abs($0.y - $1.y) < 0.018 {
                return $0.x < $1.x
            }
            return $0.y < $1.y
        }

        var clusters: [V102OCRTextRegion] = []
        for line in sorted {
            var merged = false
            for i in (0..<clusters.count).reversed() {
                let existing = clusters[i]
                let existingBottom = existing.y + existing.h
                let verticalGap = line.y - existingBottom

                let minRight = min(existing.x + existing.w, line.x + line.w)
                let maxLeft = max(existing.x, line.x)
                let horizontalOverlap = minRight - maxLeft
                let isLeftAligned = abs(existing.x - line.x) < 0.06
                let singleLineH = existing.h / CGFloat(max(1, existing.lineCount))
                let similarFontHeight = abs(singleLineH - line.h) < (singleLineH * 0.55)

                if verticalGap >= -0.015 && verticalGap <= (singleLineH * 0.95) &&
                   (horizontalOverlap > 0.05 || isLeftAligned) && similarFontHeight {
                    let newMinX = min(existing.x, line.x)
                    let newMinY = min(existing.y, line.y)
                    let newMaxX = max(existing.x + existing.w, line.x + line.w)
                    let newMaxY = max(existing.y + existing.h, line.y + line.h)

                    clusters[i] = V102OCRTextRegion(
                        rawText: existing.rawText + " " + line.rawText,
                        x: newMinX,
                        y: newMinY,
                        w: newMaxX - newMinX,
                        h: newMaxY - newMinY,
                        lineCount: existing.lineCount + 1
                    )
                    merged = true
                    break
                }
            }
            if !merged {
                clusters.append(line)
            }
        }
        return clusters
    }
}

// ============================================================================
// 3. LÕI ĐỌC DATABASE VIỆT HOÁ (.SQLITE) TRỰC TIẾP V1.02
// ============================================================================
final class V102SQLiteTranslator {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ps5.v102.sqlite.queue", qos: .userInitiated)
    private(set) var totalLines: Int = 0
    private var inMemoryLines: [(clean: String, raw: String, vi: String)] = []

    init() {
        loadDefaultDatabaseIfAvailable()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    func loadDefaultDatabaseIfAvailable() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let candidates = ["game_data.sqlite", "default_rpg.sqlite"]
        for name in candidates {
            let url = docs.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                loadDatabase(at: url)
                return
            }
        }
    }

    func loadDatabase(at url: URL) {
        queue.sync {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            inMemoryLines.removeAll()
            totalLines = 0

            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var tempDB: OpaquePointer?
            if sqlite3_open_v2(url.path, &tempDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let openedDB = tempDB {
                db = openedDB
                let tableNames = fetchTableNames(from: openedDB)
                for table in tableNames {
                    loadRows(from: openedDB, tableName: table)
                    if !inMemoryLines.isEmpty { break }
                }
                totalLines = inMemoryLines.count
            } else if let tempDB = tempDB {
                sqlite3_close(tempDB)
            }
        }
    }

    private func fetchTableNames(from dbConn: OpaquePointer) -> [String] {
        var names: [String] = []
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(dbConn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            while sqlite3_step(s) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(s, 0) {
                    names.append(String(cString: cStr))
                }
            }
            sqlite3_finalize(s)
        }
        return names
    }

    private func loadRows(from dbConn: OpaquePointer, tableName: String) {
        let sql = "SELECT * FROM \"\(tableName)\" LIMIT 50000;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbConn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        let colCount = sqlite3_column_count(s)
        guard colCount >= 2 else { return }

        while sqlite3_step(s) == SQLITE_ROW {
            var cols: [String] = []
            for i in 0..<colCount {
                if let cStr = sqlite3_column_text(s, i) {
                    cols.append(String(cString: cStr))
                } else {
                    cols.append("")
                }
            }
            if cols.count >= 4 {
                let raw = cols[1]
                let clean = cols[2].isEmpty ? Self.normalize(raw) : cols[2].lowercased()
                let vi = cols[3]
                if !vi.isEmpty {
                    inMemoryLines.append((clean: clean, raw: raw, vi: vi))
                }
            } else if cols.count == 3 {
                let raw = cols[1]
                let vi = cols[2]
                if !vi.isEmpty {
                    inMemoryLines.append((clean: Self.normalize(raw), raw: raw, vi: vi))
                }
            } else if cols.count == 2 {
                let raw = cols[0]
                let vi = cols[1]
                if !vi.isEmpty {
                    inMemoryLines.append((clean: Self.normalize(raw), raw: raw, vi: vi))
                }
            }
        }
    }

    static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet.whitespaces)
        let filtered = lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        return String(filtered)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func findBestVietnameseMatch(for englishText: String) -> String? {
        let cleanInput = Self.normalize(englishText)
        guard cleanInput.count >= 2 else { return nil }

        var bestResult: String? = nil
        queue.sync {
            guard !inMemoryLines.isEmpty else { return }

            for row in inMemoryLines {
                if row.clean == cleanInput {
                    bestResult = row.vi
                    return
                }
            }

            let inputWords = cleanInput.components(separatedBy: " ").filter { $0.count >= 3 }
            guard inputWords.count >= 2 else { return }

            var bestScore: Double = 0.0
            for row in inMemoryLines {
                var matched = 0
                for w in inputWords {
                    if row.clean.contains(w) {
                        matched += 1
                    }
                }
                let score = Double(matched) / Double(inputWords.count)
                if score > bestScore && score >= 0.72 {
                    bestScore = score
                    bestResult = row.vi
                }
            }
        }
        return bestResult
    }
}

// ============================================================================
// 4. BỘ DỊCH AI DỰ PHÒNG ĐA VÙNG (APPLE INTELLIGENCE FALLBACK ENGINE V1.02)
// ============================================================================
final class AppleIntelligenceFallbackEngine {
    static let shared = AppleIntelligenceFallbackEngine()
    private var memoryCache: [String: String] = [:]
    private var pendingRequests: Set<String> = []
    private let lock = NSLock()

    private let phraseDictionary: [(en: String, vi: String)] = [
        ("where is the key to the ancient basement", "Chìa khoá xuống tầng hầm cổ xưa ở đâu rồi?"),
        ("follow the blood trail through the dark forest", "Lần theo vết máu băng qua khu rừng tối."),
        ("follow the blood trail to the old tower", "Lần theo vết máu dẫn tới toà tháp cổ."),
        ("find 3 hidden relics in the dark forest", "Tìm 3 cổ vật bị giấu trong khu rừng tối."),
        ("silent strike - deal 250% stealth damage", "Đòn Ám Sát - Gây 250% sát thương lén lút."),
        ("ancient healing herb - restores 50% hp", "Thảo Dược Cổ Xưa - Hồi phục 50% Máu."),
        ("low health! use healing item", "Máu thấp! Hãy dùng vật phẩm hồi phục."),
        ("press [cross] to open inventory and [circle] to exit", "Nhấn [X] mở túi đồ và [O] để thoát."),
        ("quest:", "NHIỆM VỤ:"),
        ("objective:", "MỤC TIÊU:"),
        ("skill:", "KỸ NĂNG:"),
        ("item:", "VẬT PHẨM:"),
        ("menu:", "TRÌNH ĐƠN:"),
        ("deal 250% stealth damage", "gây 250% sát thương lén lút"),
        ("restores 50% hp", "hồi phục 50% Máu"),
        ("where is", "Ở đâu là"),
        ("follow the", "Hãy đi theo"),
        ("ancient basement", "tầng hầm cổ xưa"),
        ("the key to", "chìa khoá dẫn tới"),
        ("dark forest", "khu rừng tối"),
        ("hidden relics", "cổ vật ẩn giấu"),
        ("blood trail", "vết máu"),
        ("old tower", "toà tháp cổ"),
        ("system warning", "Cảnh báo hệ thống")
    ]

    func translateRegion(englishText: String, onAsyncRefined: @escaping (String) -> Void) -> String {
        let trimmed = englishText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let key = trimmed.lowercased()

        lock.lock()
        if let cached = memoryCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let instantResult = performOnDeviceContextualTranslate(trimmed)

        for item in phraseDictionary where item.en.count > 14 {
            if key.contains(item.en) {
                saveToCache(key: key, value: instantResult)
                return instantResult
            }
        }

        requestNeuralRefinement(original: trimmed, key: key, onUpdate: onAsyncRefined)
        return instantResult
    }

    private func performOnDeviceContextualTranslate(_ text: String) -> String {
        var working = text.lowercased()
        for item in phraseDictionary {
            working = working.replacingOccurrences(of: item.en, with: item.vi)
        }
        guard !working.isEmpty else { return text }
        return working.prefix(1).uppercased() + working.dropFirst()
    }

    private func requestNeuralRefinement(original: String, key: String, onUpdate: @escaping (String) -> Void) {
        lock.lock()
        if pendingRequests.contains(key) {
            lock.unlock()
            return
        }
        pendingRequests.insert(key)
        lock.unlock()

        // 1.28: đã bỏ Google Dịch (bộ dịch cũ này không còn được dùng)
        lock.lock(); pendingRequests.remove(key); lock.unlock()
        return
        guard let encoded = original.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&q=\(encoded)") else {
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = json.first as? [[Any]] else { return }

            var fullVi = ""
            for part in sentences {
                if let piece = part.first as? String {
                    fullVi += piece
                }
            }

            let finalString = fullVi.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !finalString.isEmpty {
                self.saveToCache(key: key, value: finalString)
                DispatchQueue.main.async {
                    onUpdate(finalString)
                }
            }
        }.resume()
    }

    private func saveToCache(key: String, value: String) {
        lock.lock()
        memoryCache[key] = value
        lock.unlock()
    }
}

// ============================================================================
// 5. MÁY CHỦ WEBSOCKET PHÁT PHỤ ĐỀ SANG TV SAMSUNG (GIỮ NGUYÊN CỔNG 8080)
// ============================================================================
class TVWebSocketServer: ObservableObject {
    @Published var connectedCount: Int = 0
    @Published var ipAddress: String = "Đang lấy IP..."
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var readyConnections: Set<ObjectIdentifier> = []
    /// 1.18: gói phụ đề cuối cùng -> TV vừa kết nối (hoặc kết nối lại) nhận ngay, không phải chờ câu mới
    private var lastPayload: Data?
    private var pingTimer: Timer?
    private var ipTimer: Timer?

    init() {
        ipAddress = TVWebSocketServer.currentWiFiIP() ?? "Chưa có Wi-Fi"
        start()
        // 1.18: "ping" mỗi 3 giây để TV biết kết nối còn sống (TV tự kết nối lại nếu im lặng > 10 giây)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sendControl(status: "ping")
        }
        ipTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let ip = TVWebSocketServer.currentWiFiIP() ?? "Chưa có Wi-Fi"
            if ip != self.ipAddress { self.ipAddress = ip }
        }
    }

    private func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            guard let port = NWEndpoint.Port(rawValue: AppConfig.webSocketPort) else { return }
            listener = try NWListener(using: params, on: port)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener?.stateUpdateHandler = { [weak self] state in
                // Cổng bị giữ / mạng đổi -> khởi động lại máy chủ sau 2 giây
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
                }
            }
            listener?.start(queue: .main)
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .ready:
                self.readyConnections.insert(ObjectIdentifier(conn))
                self.connectedCount = self.readyConnections.count
                // Chào để TV biết đúng là app PS5Translator (TV dùng gói này khi tự tìm iPhone)
                self.send(self.controlData(status: "hello"), to: conn)
                if let last = self.lastPayload { self.send(last, to: conn) }
                self.receiveLoop(conn)
            case .failed, .cancelled:
                self.drop(conn)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    /// Đọc liên tục để phát hiện TV đóng kết nối (nếu không đọc, NWConnection không báo đóng)
    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] _, context, isComplete, error in
            guard let self = self, let conn = conn else { return }
            if error != nil {
                conn.cancel()
                self.drop(conn)
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                conn.cancel()
                self.drop(conn)
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func drop(_ conn: NWConnection) {
        connections.removeAll(where: { $0 === conn })
        readyConnections.remove(ObjectIdentifier(conn))
        connectedCount = readyConnections.count
    }

    private func controlData(status: String) -> Data {
        let json: [String: Any] = ["status": status, "app": "PS5Translator", "boxes": [], "texts": []]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func sendControl(status: String) {
        let data = controlData(status: status)
        for conn in connections where readyConnections.contains(ObjectIdentifier(conn)) {
            send(data, to: conn)
        }
    }

    private func send(_ data: Data, to conn: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak conn] error in
            if error != nil, let conn = conn {
                conn.cancel()
                self?.drop(conn)
            }
        })
    }

    func broadcast(boxes: [TranslatedBox]) {
        let textItems = boxes.map { box -> TVTextItem in
            let xPct = (box.x <= 1.0) ? box.x * 100.0 : box.x
            let yPct = (box.y <= 1.0) ? box.y * 100.0 : box.y
            let wPct = (box.w <= 1.0) ? box.w * 100.0 : box.w
            let hPct = (box.h <= 1.0) ? box.h * 100.0 : box.h
            return TVTextItem(text: box.text, x: xPct, y: yPct, width: wPct, height: hPct)
        }
        var payload = TVPayload(status: boxes.isEmpty ? "clear" : "show", boxes: boxes)
        payload.texts = textItems
        guard let data = try? JSONEncoder().encode(payload) else { return }
        lastPayload = data
        for conn in connections where readyConnections.contains(ObjectIdentifier(conn)) {
            send(data, to: conn)
        }
    }

    /// IP Wi-Fi hiện tại của iPhone (en0). Dùng chung cho bộ cài app TV.
    static func currentWiFiIP() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                if let interface = ptr?.pointee,
                   let sa = interface.ifa_addr,
                   sa.pointee.sa_family == UInt8(AF_INET),
                   String(cString: interface.ifa_name) == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    addr = String(cString: hostname)
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return addr
    }
}

// ============================================================================
// 6. BỘ ĐIỀU PHỐI TRUNG TÂM ĐỒNG BỘ VỊ TRÍ & THỜI GIAN THỰC (V1.02)
// ============================================================================
/// 1.19: 1 dòng trong Log quét chữ
struct ScanLogEntry: Identifiable, Equatable {
    let id = UUID()
    var time: Date
    var key: String
    var kind: ScanLogKind
    var source: String
    var translation: String?
    var note: String?
}

class PipelineCoordinator: ObservableObject {
    @Published var videoMgr = VideoSourceManager()
    @Published var throttler = SmartThrottler()
    @Published var server = TVWebSocketServer()

    @Published var roiMode: ROIMode = .fullScreen
    @Published var showROIGuideBox: Bool = true

    @Published var scanFPS: Double = TranslatorV102Config.defaultScanFPS {
        didSet {
            throttler.targetScanFPS = scanFPS
        }
    }

    @Published var isShowingTVTestSentence: Bool = false

    @Published var gameProfiles: [GameProfileFolder] = []
    @Published var activeProfileFolderName: String = "Mặc định"
    @Published var loadedLineCount: Int = 0

    @Published var enableAppleIntelligenceFallback: Bool = true {
        didSet {
            smartEngine.useOnlineAI = enableAppleIntelligenceFallback
            youtubeEngine.useOnlineAI = enableAppleIntelligenceFallback
        }
    }
    /// 1.12: Bộ dịch AI (Apple Intelligence trên iPhone / Google online)
    /// 1.28: luôn dùng Data Việt hoá → Apple Intelligence trên iPhone (đã bỏ Google Dịch)
    @Published var translationEngineMode: TranslationEngineMode = .appleThenGoogle {
        didSet {
            UserDefaults.standard.set(translationEngineMode.rawValue, forKey: "translation_engine_v115")
            smartEngine.engineMode = translationEngineMode
            youtubeEngine.engineMode = translationEngineMode
            smartEngine.reset()
            youtubeEngine.reset()
        }
    }
    /// 1.12: Tab đang mở (Remote PS5 / Dịch YouTube)
    @Published var activeTab: AppTab = .ps5 {
        didSet {
            if activeTab != .ps5 { translatedBoxes = [] }
            if activeTab != .youtube { youtubeBoxes = [] }
        }
    }
    /// 1.12: Xoay ngang toàn màn hình (dùng chung cho PS5 và YouTube)
    @Published var isLandscapeFullscreen: Bool = false {
        didSet { OrientationController.setLandscape(isLandscapeFullscreen) }
    }
    /// 1.17: Không dịch chữ trên giấy / thư / biển báo (mực tối trên nền sáng)
    @Published var skipPaperText: Bool = (UserDefaults.standard.object(forKey: "skip_paper_text_v117") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(skipPaperText, forKey: "skip_paper_text_v117")
            smartEngine.skipPaperText = skipPaperText
            youtubeEngine.skipPaperText = skipPaperText
            smartEngine.reset()
            youtubeEngine.reset()
        }
    }
    @Published var youtubeBoxes: [TranslatedBox] = []
    @Published var youtubeSummary: String = "—"
    /// Số câu Việt hoá dùng được của từng game (đã kiểm tra)
    @Published var profileStats: [String: Int] = (UserDefaults.standard.dictionary(forKey: "profile_stats_v112") as? [String: Int]) ?? [:]
    @Published var importMessage: String?
    /// 1.11: Kết quả kiểm tra data Việt hoá đang dùng (hiện trong Hồ sơ game)
    @Published var databaseReport: String = "Chưa có data Việt hoá"

    @Published var translatedBoxes: [TranslatedBox] = []
    @Published var lastRecognizedEnglish: String = "Đang quét chữ thời gian thực..."

    /// 1.19: Log quét chữ hiện to trên màn hình chính (mới nhất ở đầu)
    @Published var scanLog: [ScanLogEntry] = []
    /// 1.19: Số câu theo loại trong phiên chơi (DATA / AI / RÁC...)
    @Published var logCounts: [ScanLogKind: Int] = [:]
    /// 1.19: Hiện cả chữ rác bị bỏ qua trong log
    @Published var showTrashInLog: Bool = (UserDefaults.standard.object(forKey: "show_trash_log_v119") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showTrashInLog, forKey: "show_trash_log_v119") }
    }
    /// 1.19: Tên riêng trong data Việt hoá của game đang chơi
    @Published var properNames: [String] = []
    private var logSeen: [String: (kind: ScanLogKind, at: Date)] = [:]
    private static let logRepeatWindow: TimeInterval = 20
    private static let logLimit = 120

    var visibleScanLog: [ScanLogEntry] {
        showTrashInLog ? scanLog : scanLog.filter { $0.kind != .trash }
    }

    private let smartEngine = SmartSubtitleEngine()
    private let youtubeEngine = SmartSubtitleEngine()
    private var isYouTubeProcessing = false
    var isYouTubeOCRBusy: Bool { isYouTubeProcessing }
    private var cancellables = Set<AnyCancellable>()
    private var tvTestWorkItem: DispatchWorkItem?

    private var lastScanTimestamp: TimeInterval = 0
    private var isOCRProcessing: Bool = false

    init() {
        throttler.targetScanFPS = TranslatorV102Config.defaultScanFPS
        smartEngine.engineMode = translationEngineMode
        youtubeEngine.engineMode = translationEngineMode
        smartEngine.skipPaperText = skipPaperText
        youtubeEngine.skipPaperText = skipPaperText
        youtubeEngine.onAsyncUpdate = { [weak self] boxes in
            DispatchQueue.main.async {
                guard let self = self, self.activeTab == .youtube else { return }
                self.youtubeBoxes = boxes
            }
        }
        smartEngine.onAsyncUpdate = { [weak self] boxes in
            DispatchQueue.main.async {
                guard let self = self, !self.isShowingTVTestSentence else { return }
                self.translatedBoxes = boxes
                self.server.broadcast(boxes: boxes)
            }
        }
        smartEngine.onScanLog = { [weak self] items in
            DispatchQueue.main.async { self?.ingestScanLog(items) }
        }
        setupInitialGameProfileFolders()
        refreshGameProfileFolders()

        videoMgr.$currentFullFrame
            .compactMap { $0 }
            .sink { [weak self] frame in
                self?.processFrameRealtime(frame)
            }
            .store(in: &cancellables)
    }

    func triggerTVTestSentence() {
        tvTestWorkItem?.cancel()
        isShowingTVTestSentence = true

        let testBox = TranslatedBox(
            text: TranslatorV102Config.tvTestSentence,
            x: 0.14,
            y: 0.74,
            w: 0.72,
            h: 0.12
        )

        self.lastRecognizedEnglish = "TV Test: \"\(TranslatorV102Config.tvTestSentence)\""
        self.translatedBoxes = [testBox]
        self.server.broadcast(boxes: [testBox])

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isShowingTVTestSentence = false
            self.lastRecognizedEnglish = "Đang quét chữ thời gian thực..."
        }
        tvTestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private var profilesRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("GameProfiles", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func setupInitialGameProfileFolders() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultRPG = docs.appendingPathComponent("default_rpg.sqlite")

        let sampleFolder = profilesRootURL.appendingPathComponent("Until Dawn", isDirectory: true)
        if !fm.fileExists(atPath: sampleFolder.path) {
            try? fm.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
            let destSQLite = sampleFolder.appendingPathComponent("game_data.sqlite")
            if fm.fileExists(atPath: defaultRPG.path) {
                try? fm.copyItem(at: defaultRPG, to: destSQLite)
            }
        }

        // 1.21: thêm sẵn các game có trong máy PS5 (chỉ 1 lần; game đã xoá sẽ không bị thêm lại)
        let seededKey = "preset_games_seeded_v121"
        if !UserDefaults.standard.bool(forKey: seededKey) {
            let existing = (try? fm.contentsOfDirectory(atPath: profilesRootURL.path)) ?? []
            for preset in GamePresets.all {
                if existing.contains(where: { GamePresets.matches($0, preset.name) }) { continue }
                let safeName = preset.name.replacingOccurrences(of: "/", with: "-")
                let folder = profilesRootURL.appendingPathComponent(safeName, isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }
    }

    func refreshGameProfileFolders() {
        let fm = FileManager.default
        var found: [GameProfileFolder] = []

        if let folderNames = try? fm.contentsOfDirectory(atPath: profilesRootURL.path).sorted() {
            for folder in folderNames {
                let folderURL = profilesRootURL.appendingPathComponent(folder, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
                    let contents = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
                    if let sqliteFile = contents.first(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) {
                        found.append(
                            GameProfileFolder(
                                folderName: folder,
                                sqliteFileName: sqliteFile,
                                fullSQLiteURL: folderURL.appendingPathComponent(sqliteFile)
                            )
                        )
                    } else {
                        found.append(
                            GameProfileFolder(
                                folderName: folder,
                                sqliteFileName: "Chưa có file .sqlite",
                                fullSQLiteURL: folderURL.appendingPathComponent("game_data.sqlite")
                            )
                        )
                    }
                }
            }
        }

        self.gameProfiles = found

        if let savedName = UserDefaults.standard.string(forKey: "active_profile_folder_v102"),
           let matched = found.first(where: { $0.folderName == savedName }) {
            self.activeProfileFolderName = matched.folderName
            loadTranslationDatabase(matched.fullSQLiteURL)
        } else if let first = found.first {
            self.activeProfileFolderName = first.folderName
            loadTranslationDatabase(first.fullSQLiteURL)
        }
    }

    /// 1.11: Nạp data Việt hoá bằng bộ đọc mới (tự nhận cấu trúc, báo lỗi data)
    private func loadTranslationDatabase(_ url: URL) {
        let report = smartEngine.loadDatabase(url: url)
        _ = youtubeEngine.loadDatabase(url: url)
        loadedLineCount = report.validPairs
        databaseReport = report.summary
        smartEngine.gameTitle = activeProfileFolderName
        youtubeEngine.gameTitle = activeProfileFolderName
        profileStats[activeProfileFolderName] = report.validPairs
        UserDefaults.standard.set(profileStats, forKey: "profile_stats_v112")
        properNames = smartEngine.knownNames
    }

    // MARK: - 1.19: Log quét chữ

    /// Thêm kết quả 1 lần quét vào log: không ghi lại câu đang hiện liên tục, chỉ ghi câu mới hoặc câu đổi trạng thái (AI dịch xong)
    func ingestScanLog(_ items: [ScanLogItem]) {
        guard activeTab == .ps5, !isShowingTVTestSentence else { return }
        let now = Date()
        for it in items {
            let previous = logSeen[it.key]
            logSeen[it.key] = (it.kind, now)
            if let prev = previous, prev.kind == it.kind, now.timeIntervalSince(prev.at) < Self.logRepeatWindow { continue }
            if let prev = previous, prev.kind != it.kind, let idx = scanLog.firstIndex(where: { $0.key == it.key }) {
                // Đổi trạng thái (vd: AI đang dịch -> AI xong): cập nhật dòng cũ và đưa lên đầu
                var entry = scanLog.remove(at: idx)
                entry.kind = it.kind
                entry.translation = it.translation
                entry.note = it.note
                entry.time = now
                scanLog.insert(entry, at: 0)
            } else {
                scanLog.insert(ScanLogEntry(time: now, key: it.key, kind: it.kind, source: it.source,
                                            translation: it.translation, note: it.note), at: 0)
            }
            if it.kind != .pending { logCounts[it.kind, default: 0] += 1 }
        }
        if scanLog.count > Self.logLimit { scanLog.removeLast(scanLog.count - Self.logLimit) }
        if logSeen.count > 600 {
            logSeen = logSeen.filter { now.timeIntervalSince($0.value.at) < 60 }
        }
    }

    func clearScanLog() {
        scanLog = []
        logCounts = [:]
        logSeen = [:]
    }

    /// Văn bản log để chia sẻ / lưu
    func scanLogExportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let lines = scanLog.reversed().map { e -> String in
            var line = "[\(f.string(from: e.time))] \(e.kind.rawValue.uppercased()): \(e.source)"
            if let vi = e.translation { line += "  →  \(vi)" }
            if let n = e.note { line += "  (\(n))" }
            return line
        }
        return "PS5Translator – Log quét chữ – \(activeProfileFolderName)\n" + lines.joined(separator: "\n")
    }

    /// 1.12: Nạp data Việt hoá: .sqlite/.db chép thẳng, .csv/.tsv/.txt tự chuyển sang SQLite chuẩn
    func importDataIntoProfileFolder(folderName: String, sourceURL: URL) {
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "sqlite" || ext == "db" || ext == "sqlite3" {
            importSQLiteIntoProfileFolder(folderName: folderName, sourceURL: sourceURL)
            importMessage = "✅ Đã nạp \(sourceURL.lastPathComponent) cho \(folderName). \(databaseReport)"
            return
        }
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        do {
            let pairs = try DataImporter.readPairs(from: sourceURL)
            if let oldFiles = try? fm.contentsOfDirectory(atPath: folderURL.path) {
                for old in oldFiles where old.hasSuffix(".sqlite") || old.hasSuffix(".db") {
                    try? fm.removeItem(at: folderURL.appendingPathComponent(old))
                }
            }
            let count = try DataImporter.writeSQLite(pairs: pairs, to: folderURL.appendingPathComponent("game_data.sqlite"))
            activateGameProfileFolder(folderName: folderName)
            importMessage = "✅ Đã chuyển \(sourceURL.lastPathComponent) thành data: \(count) cặp Anh → Việt."
        } catch {
            importMessage = "⚠️ Không nạp được \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            refreshGameProfileFolders()
        }
    }

    func processYouTubeFrame(_ frame: CGImage) {
        guard activeTab == .youtube, !isYouTubeProcessing else { return }
        isYouTubeProcessing = true
        youtubeEngine.useOnlineAI = enableAppleIntelligenceFallback
        youtubeEngine.process(frame: frame, cropped: frame, roi: CGRect(x: 0, y: 0, width: 1, height: 1)) { [weak self] boxes, summary in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isYouTubeProcessing = false
                guard self.activeTab == .youtube else { return }
                self.youtubeSummary = summary
                if boxes != self.youtubeBoxes { self.youtubeBoxes = boxes }
            }
        }
    }

    func resetYouTubeTracking() {
        youtubeEngine.reset()
        youtubeBoxes = []
    }

    func createNewGameProfileFolder(folderName: String) {
        let cleanName = folderName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let folderURL = profilesRootURL.appendingPathComponent(cleanName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        refreshGameProfileFolders()
        DataBackup.scheduleAutoBackup()
    }

    func importSQLiteIntoProfileFolder(folderName: String, sourceURL: URL) {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let cleanFolder = folderName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "Hồ sơ mới" : folderName
        let folderURL = profilesRootURL.appendingPathComponent(cleanFolder, isDirectory: true)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        if let oldFiles = try? fm.contentsOfDirectory(atPath: folderURL.path) {
            for old in oldFiles where old.hasSuffix(".sqlite") || old.hasSuffix(".db") {
                try? fm.removeItem(at: folderURL.appendingPathComponent(old))
            }
        }

        let fileName = sourceURL.lastPathComponent
        let destInFolder = folderURL.appendingPathComponent(fileName)
        try? fm.copyItem(at: sourceURL, to: destInFolder)

        activateGameProfileFolder(folderName: cleanFolder)
    }

    func activateGameProfileFolder(folderName: String) {
        let fm = FileManager.default
        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)
        let contents = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []

        if activeProfileFolderName != folderName { clearScanLog() }
        activeProfileFolderName = folderName
        if let sqliteFile = contents.first(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) {
            let sourceSQLiteURL = folderURL.appendingPathComponent(sqliteFile)
            loadTranslationDatabase(sourceSQLiteURL)
        } else {
            loadedLineCount = 0
            databaseReport = "Game này chưa có data Việt hoá → dịch bằng AI"
            properNames = []
            smartEngine.clearDatabase()      // 1.28: không dùng data của game trước
            youtubeEngine.clearDatabase()
            smartEngine.gameTitle = folderName
            youtubeEngine.gameTitle = folderName
        }

        UserDefaults.standard.set(folderName, forKey: "active_profile_folder_v102")
        refreshGameProfileFolders()
        DataBackup.scheduleAutoBackup()   // 1.26: tự sao lưu data ra app Tệp
    }

    func deleteGameProfileFolder(folderName: String) {
        GameCoverStore.shared.forget(name: folderName)
        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folderURL)
        refreshGameProfileFolders()
        DataBackup.scheduleAutoBackup()
    }

    // MARK: - 1.11: Luồng quét chữ thông minh (lọc rác, giữ khung ổn định, khớp kiểu chữ gốc)
    private func processFrameRealtime(_ frame: CGImage) {
        guard !isShowingTVTestSentence, activeTab == .ps5 else { return }
        guard !isOCRProcessing, !smartEngine.isBusy else { return }

        let now = Date().timeIntervalSince1970
        let minInterval = 1.0 / max(1.0, scanFPS)
        guard (now - lastScanTimestamp) >= minInterval else { return }

        guard let cropped = videoMgr.cropFrameToSmartROI(fullImage: frame, mode: roiMode) else { return }
        lastScanTimestamp = now
        isOCRProcessing = true

        let roiRect = videoMgr.getNormalizedROIRect(for: roiMode)
        smartEngine.useOnlineAI = enableAppleIntelligenceFallback

        smartEngine.process(frame: frame, cropped: cropped, roi: roiRect) { [weak self] boxes, summary in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isOCRProcessing = false
                guard !self.isShowingTVTestSentence else { return }
                self.lastRecognizedEnglish = summary
                if boxes != self.translatedBoxes {
                    self.translatedBoxes = boxes
                    self.server.broadcast(boxes: boxes)
                }
            }
        }
    }
}

