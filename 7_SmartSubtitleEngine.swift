// ============================================================================
// FILE 7: 7_SmartSubtitleEngine.swift
// PHIÊN BẢN: PS5Translator 1.24 (KHÔNG BAO GIỜ BỎ TÊN RIÊNG TRONG CÂU THOẠI: "Sam")
//
// Luồng xử lý mỗi lần quét:
//  1. OCR Apple Vision (.accurate) -> lấy từng DÒNG + toạ độ TỪNG TỪ.
//  2. GameTextFilter: bỏ chữ "rác" (vệt tối bị đọc nhầm, ký tự lạ, số HUD, chữ đơn lẻ
//     vô nghĩa, từ tiếng Anh cơ bản mà game thủ đã hiểu như OK/BACK/HP...).
//  3. Tách nút bấm tay cầm (L1, R2, ✕, ○, △, □...) và khoảng trống chứa icon nút
//     -> chia câu thành nhiều đoạn, khung dịch KHÔNG đè lên nút.
//  4. Gom dòng thành khối (phụ đề 2 dòng), nhận diện tên người nói [Ashley].
//  5. Dịch: Data Việt hoá (khớp chính xác -> khớp gần đúng) -> từ điển menu game
//     -> dịch AI online (giữ nguyên tên riêng) -> lưu bộ nhớ đệm.
//  6. StableSubtitleTracker: giữ ID + vị trí khung ổn định (không nhảy), chỉ hiện chữ
//     khi đã chắc chắn, ẩn ngay khi chữ gốc biến mất.
//  7. Lấy màu chữ / màu nền thật từ khung hình, thoại nhân vật = màu vàng.
//  8. SubtitleLayoutEngine: khung dịch neo đúng góc trái-trên chữ gốc, kéo dài sang
//     phải, tự xuống dòng, thu nhỏ chữ để không đè khung khác / nút bấm.
// ============================================================================

import Foundation
import Vision
import CoreGraphics
import UIKit
import SQLite3

// MARK: - Mô hình dữ liệu nội bộ

struct SSWord {
    var text: String
    var rect: CGRect          // toạ độ chuẩn hoá trên TOÀN khung hình, gốc trái-trên
}

struct SSLine {
    var text: String
    var confidence: Float
    var rect: CGRect
    var words: [SSWord]
    /// 1.16: độ nghiêng (độ) và độ méo phối cảnh của dòng chữ -> chữ in trên vật phẩm 3D thường nghiêng/méo
    var skewDegrees: CGFloat = 0
    var shearRatio: CGFloat = 0
}

struct SSStyle: Equatable {
    var textRGB: (Double, Double, Double)
    var backgroundRGB: (Double, Double, Double)
    var isBold: Bool
    /// 1.17: chữ TỐI trên nền SÁNG (mực trên giấy / biển báo)
    var darkOnLight: Bool = false

    static let fallback = SSStyle(textRGB: (1, 1, 1), backgroundRGB: (0.05, 0.05, 0.07), isBold: true)

    static func == (a: SSStyle, b: SSStyle) -> Bool {
        a.textRGB == b.textRGB && a.backgroundRGB == b.backgroundRGB && a.isBold == b.isBold && a.darkOnLight == b.darkOnLight
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
}

/// 1.19: Loại dòng log quét chữ
enum ScanLogKind: String {
    case data, ai, pending, missing, trash
}

/// 1.19: 1 dòng log của 1 lần quét (engine -> bộ điều phối)
struct ScanLogItem {
    let key: String
    let kind: ScanLogKind
    let source: String
    let translation: String?
    let note: String?
}

/// 1 đơn vị chữ cần dịch + vẽ khung (1 khối thoại, 1 dòng menu hoặc 1 đoạn giữa 2 nút bấm)
struct SSPiece {
    var sourceText: String
    var speaker: String?
    var rect: CGRect
    var lineCount: Int
    var category: TextRegionCategory
    var confidence: Float
    var validRatio: Double
    var wordCount: Int
    /// Giới hạn mép phải (không được vẽ qua): mép trái của nút bấm kế tiếp
    var rightLimit: CGFloat?
    /// Tên người nói giữ nguyên kiểu ngoặc gốc: "(Dr. Hill)" hoặc "[Ashley]"
    var speakerLabel: String? = nil
    /// Chữ này có trong data Việt hoá (chắc chắn không phải chữ rác)
    var knownInData: Bool = false
}

// MARK: - Từ vựng game

enum GameVocabulary {
    /// Nút bấm tay cầm PS5 (so sánh chữ thường). Không dịch, không che.
    static let controllerTokens: Set<String> = [
        "l1", "l2", "l3", "r1", "r2", "r3", "x", "o", "✕", "✖", "×", "○", "◯", "△", "□", "▢", "⨯",
        "[x]", "[o]", "(x)", "(o)", "[l1]", "[r1]", "[l2]", "[r2]", "[l3]", "[r3]",
        "options", "touchpad", "create", "share", "ps", "d-pad", "dpad", "©", "®", "@"
    ]

    /// Từ tiếng Anh cơ bản game thủ đều hiểu -> đứng một mình thì KHÔNG cần dịch (giảm rối mắt)
    static let basicGamerWords: Set<String> = [
        "ok", "back", "start", "select", "menu", "pause", "hp", "mp", "sp", "xp", "exp", "lv", "lvl",
        "level", "yes", "no", "play", "next", "enter", "exit", "fps", "hud", "boss", "combo", "game",
        "new", "loading", "auto", "on", "off", "max", "min", "ps5", "ps4", "playstation", "online",
        "offline", "home", "ready", "go", "win", "lose", "victory", "game over", "the end"
    ]

    /// Hiệu ứng / thông số HUD không bao giờ dịch
    static let screenEffects: Set<String> = [
        "critical", "miss", "dodge", "parry", "slash", "boom", "bam", "hit", "hits", "fps", "hp", "mp"
    ]

    /// Từ điển menu / thao tác game hay gặp (khớp nguyên cụm đã chuẩn hoá)
    static let uiDictionary: [String: String] = [
        "press": "Nhấn", "hold": "Giữ", "tap": "Chạm", "release": "Thả",
        "to": "để", "or": "hoặc", "and": "và",
        "continue": "Tiếp tục", "resume": "Tiếp tục", "options": "Tuỳ chọn", "settings": "Cài đặt",
        "quit": "Thoát", "quit game": "Thoát trò chơi", "save": "Lưu", "load": "Tải", "load game": "Tải trò chơi",
        "new game": "Trò chơi mới", "chapter select": "Chọn chương", "chapters": "Các chương", "chapter": "Chương",
        "inventory": "Túi đồ", "map": "Bản đồ", "objective": "Mục tiêu", "objectives": "Mục tiêu",
        "examine": "Xem xét", "inspect": "Kiểm tra", "pick up": "Nhặt", "interact": "Tương tác",
        "open": "Mở", "close": "Đóng", "use": "Dùng", "equip": "Trang bị", "drop": "Bỏ",
        "confirm": "Xác nhận", "cancel": "Huỷ", "skip": "Bỏ qua", "retry": "Thử lại",
        "difficulty": "Độ khó", "easy": "Dễ", "normal": "Thường", "hard": "Khó",
        "subtitles": "Phụ đề", "audio": "Âm thanh", "controls": "Điều khiển", "display": "Hiển thị",
        "brightness": "Độ sáng", "language": "Ngôn ngữ", "credits": "Danh đề", "extras": "Bổ sung",
        "collectibles": "Vật phẩm sưu tầm", "clues": "Manh mối", "totems": "Vật tổ", "characters": "Nhân vật",
        "relationships": "Mối quan hệ", "traits": "Tính cách", "don't move": "Đừng cử động",
        "hide": "Trốn", "run": "Chạy", "aim": "Ngắm", "shoot": "Bắn", "reload": "Nạp đạn",
        "throw": "Ném", "climb": "Leo", "jump": "Nhảy", "crouch": "Ngồi xuống", "sprint": "Chạy nhanh",
        "attack": "Tấn công", "heavy attack": "Đòn mạnh", "light attack": "Đòn nhẹ", "block": "Đỡ đòn",
        "parry": "Đỡ phản", "dodge": "Né", "heal": "Hồi máu", "look": "Nhìn", "move": "Di chuyển",
        "zoom": "Phóng to", "rotate": "Xoay", "flip": "Lật", "read": "Đọc", "talk": "Nói chuyện",
        "follow": "Đi theo", "search": "Tìm kiếm", "previously": "Trước đó", "saving": "Đang lưu",
        "autosave": "Tự động lưu", "loading complete": "Tải xong", "press any button": "Nhấn nút bất kỳ"
    ]

    /// Tên riêng có sẵn (Until Dawn) - không dịch. Data Việt hoá có thể bổ sung qua bảng glossary.
    static let builtInNames: Set<String> = [
        "sam", "samantha", "mike", "michael", "jessica", "jess", "josh", "joshua", "chris", "christopher",
        "ashley", "emily", "em", "matt", "matthew", "hannah", "beth", "bethany", "hill", "alan",
        "washington", "blackwood", "jefferson", "billy", "bates", "stranger", "wendigo", "alberta",
        "ranger", "sanatorium", "mia", "lindsay"
    ]
}

// MARK: - Bộ lọc chữ "rác"

final class GameTextFilter {
    private var checker: UITextChecker?
    private var wordCache: [String: Bool] = [:]
    var extraNames: Set<String> = []

    struct Analysis {
        var isMeaningful: Bool
        var validRatio: Double
        var alphaWords: Int
        var dictionaryWords: Int
    }

    func isEnglishWord(_ raw: String) -> Bool {
        let w = raw.lowercased()
        if w.count <= 1 { return w == "a" || w == "i" }
        if let cached = wordCache[w] { return cached }
        if checker == nil { checker = UITextChecker() }
        let ns = w as NSString
        let range = checker!.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: ns.length),
                                                   startingAt: 0, wrap: false, language: "en_US")
        let ok = range.location == NSNotFound
        if wordCache.count > 20000 { wordCache.removeAll() }
        wordCache[w] = ok
        return ok
    }

    /// "Hannah's" -> "Hannah"
    static func stripPossessive(_ w: String) -> String {
        for suf in ["'s", "’s", "'S", "’S"] where w.hasSuffix(suf) && w.count > 3 {
            return String(w.dropLast(2))
        }
        return w
    }

    func isName(_ raw: String) -> Bool {
        let w = Self.stripPossessive(raw).lowercased()
        return GameVocabulary.builtInNames.contains(w) || extraNames.contains(w)
    }

    /// Phân tích 1 dòng / 1 đoạn chữ xem có phải chữ thật cần dịch không
    func analyze(_ text: String) -> Analysis {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ký tự lạ đặc trưng của OCR đọc nhầm hoa văn / vệt sáng
        let junkChars = trimmed.filter { "{}<>\\~^_=`¦§¤".contains($0) }.count
        if junkChars > 0 { return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0) }

        let nonSpace = trimmed.filter { !$0.isWhitespace }
        let letters = nonSpace.filter { $0.isLetter }
        if letters.count < 2 || Double(letters.count) / Double(max(1, nonSpace.count)) < 0.6 {
            return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0)
        }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var alpha = 0, valid = 0, dict = 0
        for tok in tokens {
            let core = tok.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            guard core.contains(where: { $0.isLetter }) else { continue }
            if GameVocabulary.controllerTokens.contains(core.lowercased()) { continue }
            alpha += 1
            if Self.looksLikeGarbageToken(core) { continue }
            let plain = core.replacingOccurrences(of: "’", with: "'")
            if isEnglishWord(plain) || isEnglishWord(plain.replacingOccurrences(of: "'", with: "")) {
                valid += 1; dict += 1
            } else if isName(core) || Self.isProperNounCandidate(core) {
                valid += 1
            } else if core.count <= 3 && core.uppercased() == core {
                valid += 1 // từ viết tắt ngắn: HP, NPC, OK...
            }
        }
        guard alpha > 0 else { return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0) }
        let ratio = Double(valid) / Double(alpha)
        let meaningful: Bool
        if alpha == 1 {
            meaningful = dict == 1 && letters.count >= 3
        } else {
            meaningful = ratio >= 0.65 && dict >= max(1, alpha / 3)
        }
        return Analysis(isMeaningful: meaningful, validRatio: ratio, alphaWords: alpha, dictionaryWords: dict)
    }

    /// "uKCTrTr4C", "li'i{'", "b3ng": trộn chữ-số, hoa-thường lộn xộn
    static func looksLikeGarbageToken(_ t: String) -> Bool {
        let chars = Array(t)
        let digits = chars.filter { $0.isNumber }.count
        let lettersCount = chars.filter { $0.isLetter }.count
        if digits > 0 && lettersCount > 0 {
            // cho phép 2nd, 10th, 3D, L1...
            let lower = t.lowercased()
            let okPatterns = ["st", "nd", "rd", "th", "d", "s", "x", "k", "m"]
            let letterPart = String(lower.filter { $0.isLetter })
            if !(okPatterns.contains(letterPart) || GameVocabulary.controllerTokens.contains(lower)) { return true }
        }
        // số lần đổi thường -> hoa bên trong từ
        var switches = 0
        for i in 1..<max(1, chars.count) where i < chars.count {
            if chars[i - 1].isLowercase && chars[i].isUppercase { switches += 1 }
        }
        if switches >= 2 { return true }
        if chars.count >= 2 && chars[0].isLowercase && chars.dropFirst().allSatisfy({ $0.isUppercase }) { return true }
        // 4 phụ âm/nguyên âm lặp kỳ lạ
        if t.count >= 4 && Set(t.lowercased()).count == 1 { return true }
        return false
    }

    static func isProperNounCandidate(_ t: String) -> Bool {
        guard let first = t.first, first.isUppercase, t.count >= 3 else { return false }
        let rest = t.dropFirst()
        return rest.allSatisfy { $0.isLowercase || $0 == "'" || $0 == "-" }
    }
}

// MARK: - OCR (Apple Vision) lấy toạ độ từng từ

final class SmartOCREngine {
    func recognize(cropped: CGImage, roi: CGRect, customWords: [String]) -> [SSLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Nhận cả tiếng Việt: chữ đã là tiếng Việt (giao diện PS5, game đã Việt hoá) sẽ được bỏ qua
        var langs = ["en-US"]
        if let supported = try? request.supportedRecognitionLanguages(), supported.contains("vi-VT") {
            langs.append("vi-VT")
        }
        request.recognitionLanguages = langs
        // 1.16: đọc được chữ nhỏ (nhãn địa điểm, ghi chú ~10px) -> trước đây 0.018 làm chữ nhỏ lúc có lúc không
        request.minimumTextHeight = 0.011
        if !customWords.isEmpty { request.customWords = Array(customWords.prefix(200)) }

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observations = request.results else { return [] }

        func toFrame(_ b: CGRect) -> CGRect {
            let topY = 1.0 - b.origin.y - b.size.height
            return CGRect(x: roi.origin.x + b.origin.x * roi.size.width,
                          y: roi.origin.y + topY * roi.size.height,
                          width: b.size.width * roi.size.width,
                          height: b.size.height * roi.size.height)
        }

        var lines: [SSLine] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let str = cand.string
            let lineRect = toFrame(obs.boundingBox)
            var words: [SSWord] = []
            var idx = str.startIndex
            while idx < str.endIndex {
                while idx < str.endIndex && str[idx].isWhitespace { idx = str.index(after: idx) }
                guard idx < str.endIndex else { break }
                var end = idx
                while end < str.endIndex && !str[end].isWhitespace { end = str.index(after: end) }
                let range = idx..<end
                if let box = try? cand.boundingBox(for: range) {
                    words.append(SSWord(text: String(str[range]), rect: toFrame(box.boundingBox)))
                }
                idx = end
            }
            if words.isEmpty {
                words = [SSWord(text: str, rect: lineRect)]
            }
            // Độ nghiêng của đường chân chữ và độ méo cạnh trái (theo pixel ảnh)
            let iw = CGFloat(cropped.width), ih = CGFloat(cropped.height)
            let dx = (obs.topRight.x - obs.topLeft.x) * iw
            let dy = (obs.topRight.y - obs.topLeft.y) * ih
            let angle = abs(atan2(dy, dx) * 180 / .pi)
            let heightPx = max(1, (obs.topLeft.y - obs.bottomLeft.y) * ih)
            let shear = abs((obs.topLeft.x - obs.bottomLeft.x) * iw) / heightPx
            var line = SSLine(text: str, confidence: cand.confidence, rect: lineRect, words: words)
            line.skewDegrees = angle
            line.shearRatio = shear
            lines.append(line)
        }
        return lines
    }
}

// MARK: - Tách đoạn quanh nút bấm, gom dòng, nhận diện người nói

enum PieceBuilder {
    static let refW: CGFloat = 1280
    static let refH: CGFloat = 720

    static func isControllerToken(_ t: String) -> Bool {
        let core = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        if GameVocabulary.controllerTokens.contains(core) { return true }
        // 1.14: icon nút bị OCR đọc lệch: "[12]", "(12)", "(2)", "(r2)", "[R2)", "(kz)", "(@]", "[7"
        let brackets = "[](){}"
        let hasOpen = core.contains { "[({".contains($0) }
        let hasClose = core.contains { "])}".contains($0) }
        let inner = core.filter { !brackets.contains($0) && $0 != "|" }
        let hasDigit = inner.contains { $0.isNumber }
        if (hasOpen || hasClose) && inner.count <= 3 && ((hasOpen && hasClose) || hasDigit) { return true }
        return false
    }

    /// Chia 1 dòng thành các đoạn chữ nằm giữa các nút bấm / khoảng trống chứa icon
    static func segments(of line: SSLine, refW: CGFloat = 1280) -> [(words: [SSWord], rightLimit: CGFloat?)] {
        let words = line.words.sorted { $0.rect.minX < $1.rect.minX }
        let lineHpx = line.rect.height * refH
        var result: [(words: [SSWord], rightLimit: CGFloat?)] = []
        var current: [SSWord] = []

        for (i, w) in words.enumerated() {
            if isControllerToken(w.text) {
                if !current.isEmpty {
                    result.append((current, w.rect.minX - 0.004))
                    current = []
                }
                continue
            }
            if let prev = current.last ?? (i > 0 ? words[i - 1] : nil), !current.isEmpty {
                let gapPx = (w.rect.minX - prev.rect.maxX) * refW
                // 1.13: khoảng trống sau tên người nói "(Dr. Hill)   Interesting." KHÔNG phải icon nút
                let afterSpeaker = current.count <= 3 && (prev.text.hasSuffix(")") || prev.text.hasSuffix("]") || prev.text.hasSuffix(":"))
                if !afterSpeaker && gapPx > max(26, lineHpx * 2.0) {
                    // Khoảng trống lớn = icon nút bấm Vision không đọc được -> ngắt khung
                    result.append((current, prev.rect.maxX + (w.rect.minX - prev.rect.maxX) * 0.2))
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { result.append((current, nil)) }
        return result
    }

    /// 1.13: Vision hay tách "(Dr. Hill)" và lời thoại thành 2 dòng cùng hàng -> gộp lại
    static func mergeRowFragments(_ lines: [SSLine], refW: CGFloat) -> [SSLine] {
        let sorted = lines.sorted { $0.rect.minX < $1.rect.minX }
        var rows: [SSLine] = []
        for line in sorted {
            if let i = rows.firstIndex(where: { row in
                let h = max(row.rect.height, line.rect.height)
                let sameRow = abs(row.rect.midY - line.rect.midY) < h * 0.35
                let similarH = abs(row.rect.height - line.rect.height) < h * 0.35
                let gapPx = (line.rect.minX - row.rect.maxX) * refW
                return sameRow && similarH && gapPx > -h * refH * 0.5 && gapPx < max(48, h * refH * 3.5)
            }) {
                var row = rows[i]
                // 1.20: độ tin cậy theo mảnh DÀI hơn: nhãn "(Sam)" ngắn hay bị chấm thấp, không được kéo cả câu xuống
                row.confidence = row.text.count >= line.text.count ? row.confidence : line.confidence
                row.text = row.text + " " + line.text
                row.rect = row.rect.union(line.rect)
                row.words += line.words
                rows[i] = row
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    /// Nhận diện tên người nói ở đầu phụ đề: "[Ashley] ...", "IAshleyl ..." (OCR đọc [ ] thành I l), "Ashley: ..."
    static func extractSpeaker(_ text: String, filter: GameTextFilter) -> (speaker: String?, label: String?, rest: String) {
        let pattern = "^\\s*([\\[\\(\\{|Il1])\\s?([A-Z][A-Za-z\\.\\-']{1,20}(?: [A-Z][A-Za-z\\.\\-']{1,20})?)\\s?([\\]\\)\\}|Il1:])\\s+(.+)$"
        if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
           let r4 = Range(m.range(at: 4), in: text) {
            let open = String(text[r1])
            let name = String(text[r2])
            let realBracket = open == "[" || open == "(" || open == "{"
            let known = name.split(separator: " ").allSatisfy { filter.isName(String($0)) }
            if realBracket || known {
                let label = open == "(" ? "(\(name))" : (open == "{" ? "{\(name)}" : "[\(name)]")
                return (name, label, String(text[r4]))
            }
        }
        // "Ashley: Hello"
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 22 {
            let name = text[..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.split(separator: " ").allSatisfy({ filter.isName(String($0)) }) {
                return (name, name + ":", String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (nil, nil, text)
    }

    /// 1.20: mảnh chữ CHỈ là nhãn người nói "(Sam)", "[Ashley]", "Chris:" (Vision hay tách riêng khỏi lời thoại)
    static func speakerLabelOnly(_ text: String, filter: GameTextFilter) -> (name: String, label: String)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let pattern = "^([\\[\\(\\{])\\s?([A-Z][A-Za-z\\.\\-']{1,20}(?: [A-Z][A-Za-z\\.\\-']{1,20})?)\\s?([\\]\\)\\}|Il1])?$"
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t) {
            let open = String(t[r1]), name = String(t[r2])
            let parts = name.split(separator: " ").map(String.init)
            // "(Options)", "[Back]" là chữ menu, không phải tên người nói
            let known = parts.allSatisfy { filter.isName($0) || ["dr.", "mr.", "mrs.", "ms."].contains($0.lowercased()) }
            guard known || !parts.contains(where: { filter.isEnglishWord($0.lowercased()) }) else { return nil }
            let label = open == "(" ? "(\(name))" : (open == "{" ? "{\(name)}" : "[\(name)]")
            return (name, label)
        }
        // "Sam)" (OCR làm mất ngoặc mở) hoặc "Sam:" -> chỉ nhận khi là tên đã biết
        if t.hasSuffix(")") || t.hasSuffix("]") || t.hasSuffix(":") {
            let name = String(t.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "([{ "))
            if !name.isEmpty, name.split(separator: " ").count <= 2,
               name.split(separator: " ").allSatisfy({ filter.isName(String($0)) }) {
                return (name, t.hasSuffix(":") ? name + ":" : "(\(name))")
            }
        }
        return nil
    }

    /// 1.16: dòng chỉ gồm tên riêng ("SAM", "Hannah", "Dr. Hill") -> không cần dịch
    static func isNamesOnly(_ text: String, filter: GameTextFilter) -> Bool {
        let words = text.split(separator: " ").map { GameTextFilter.stripPossessive(String($0).trimmingCharacters(in: .punctuationCharacters)) }
            .filter { $0.contains(where: { $0.isLetter }) }
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { w in filter.isName(w) || ["dr", "mr", "mrs", "ms"].contains(w.lowercased()) }
    }

    /// 1.13: lựa chọn câu trả lời / menu ngắn (1-4 từ, toàn từ hợp lệ) không phải chữ rác
    static func isChoiceLike(_ a: GameTextFilter.Analysis) -> Bool {
        a.alphaWords >= 1 && a.alphaWords <= 4 && a.validRatio >= 0.99 && a.dictionaryWords >= 1
    }

    static func classify(rect: CGRect, wordCount: Int, hasSpeaker: Bool, text: String = "") -> TextRegionCategory {
        if hasSpeaker { return .dialogue }
        // 1.16: chữ IN HOA không có người nói ("TEN HOURS UNTIL DAWN") là tiêu đề / nhãn, không phải lời thoại
        let allCaps = SmartSubtitleEngine.isAllCaps(text)
        if !allCaps && rect.midY >= 0.62 && abs(rect.midX - 0.5) < 0.25 && wordCount >= 3 { return .dialogue }
        if rect.midY <= 0.30 && (rect.midX <= 0.35 || rect.midX >= 0.65) { return .quest }
        return .menu
    }

    /// Dòng -> các khối cần dịch
    static func buildPieces(lines inputLines: [SSLine], filter: GameTextFilter, refW: CGFloat = 1280,
                            isKnownText: (String) -> Bool = { _ in false }) -> [SSPiece] {
        var plainLines: [SSLine] = []
        var pieces: [SSPiece] = []
        /// 1.20: nhãn người nói đứng riêng -> gắn lại vào lời thoại cùng hàng (KHÔNG bỏ đi như bản 1.16)
        var labels: [(name: String, label: String, rect: CGRect)] = []
        let rawLines = mergeRowFragments(inputLines.filter { !TranslationMemory.hasVietnameseMarks($0.text) }, refW: refW)

        for line in rawLines {
            // 1.20: nhãn người nói "(Sam)" -> giữ lại để gắn vào lời thoại (OCR hay chấm điểm thấp cho chữ ngắn)
            if let sp = speakerLabelOnly(line.text, filter: filter) {   // 1.24: không lọc theo độ tin cậy
                labels.append((sp.name, sp.label, line.rect))
                continue
            }
            guard line.confidence >= 0.45 else { continue }
            if TranslationMemory.hasVietnameseMarks(line.text) { continue }   // đã là tiếng Việt
            let hPx = line.rect.height * refH
            // 1.16: quá nhỏ (số HUD) hoặc CHỮ TO (tên nhân vật "SAM", tiêu đề chương "MEMENTO MORI")
            // -> không dịch để không che màn hình game
            guard hPx >= 7.5, hPx <= 50 else { continue }
            // 1.16: chữ in trên vật phẩm 3D (lá thư, biển báo, chữ viết tay) thường nghiêng / méo phối cảnh
            if line.skewDegrees > 3.0 || line.shearRatio > 0.22 { continue }

            let segs = segments(of: line, refW: refW)
            if segs.count == 1 && segs[0].rightLimit == nil && segs[0].words.count == line.words.count {
                plainLines.append(line)
                continue
            }
            // Dòng có nút bấm: mỗi đoạn là 1 khung riêng, không gom với dòng khác
            for seg in segs {
                let text = seg.words.map { $0.text }.joined(separator: " ")
                let a = filter.analyze(text)
                let norm = TranslationMemory.normalize(text)
                let isUI = GameVocabulary.uiDictionary[norm] != nil
                let known = isKnownText(text)
                if let sp = speakerLabelOnly(text, filter: filter) {
                    labels.append((sp.name, sp.label, union(seg.words.map { $0.rect })))
                    continue
                }
                if isNamesOnly(text, filter: filter) { continue }
                guard a.isMeaningful || isUI || known || isChoiceLike(a) else { continue }
                let rect = union(seg.words.map { $0.rect })
                var piece = SSPiece(sourceText: text, speaker: nil, rect: rect, lineCount: 1,
                                    category: classify(rect: rect, wordCount: a.alphaWords, hasSpeaker: false, text: text),
                                    confidence: line.confidence, validRatio: a.validRatio,
                                    wordCount: a.alphaWords, rightLimit: seg.rightLimit)
                piece.knownInData = known
                pieces.append(piece)
            }
        }

        // Gom các dòng thường thành khối (phụ đề 2 dòng, đoạn mô tả...)
        let sorted = plainLines.sorted { $0.rect.minY < $1.rect.minY }
        var blocks: [[SSLine]] = []
        for line in sorted {
            let lineWords = line.words.count
            var merged = false
            for i in (0..<blocks.count).reversed() {
                guard let last = blocks[i].last else { continue }
                let lastWords = last.words.count
                let hA = last.rect.height, hB = line.rect.height
                let similarH = abs(hA - hB) < max(hA, hB) * 0.35
                let gap = line.rect.minY - last.rect.maxY
                let closeV = gap >= -hA * 0.3 && gap <= hA * 0.9
                let centerAligned = abs(line.rect.midX - last.rect.midX) < 0.06
                let leftAligned = abs(line.rect.minX - last.rect.minX) < 0.025
                let overlapX = min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX) > 0
                let endsItem = last.text.hasSuffix(":")
                if lastWords >= 2 && lineWords >= 2 && similarH && closeV && (centerAligned || leftAligned) && overlapX && !endsItem {
                    blocks[i].append(line)
                    merged = true
                    break
                }
            }
            if !merged { blocks.append([line]) }
        }

        for block in blocks {
            let joined = block.map { $0.text }.joined(separator: " ")
            let (speaker, label, rest) = extractSpeaker(joined, filter: filter)
            let a = filter.analyze(rest)
            let norm = TranslationMemory.normalize(rest)
            let known = isKnownText(rest)
            // 1.24: "(Chris) Sam!" là lời thoại gọi tên -> GIỮ (trước đây bị bỏ vì "chỉ có tên riêng")
            let namesOnly = isNamesOnly(rest, filter: filter)
            if namesOnly && speaker == nil { continue }
            // Từ game cơ bản đứng một mình thì bỏ, NHƯNG lời thoại có người nói ("(Josh) No.") vẫn dịch
            if speaker == nil && !known && GameVocabulary.basicGamerWords.contains(norm) { continue }
            if speaker == nil && GameVocabulary.screenEffects.contains(norm) { continue }
            let isUI = GameVocabulary.uiDictionary[norm] != nil
            guard a.isMeaningful || isUI || known || isChoiceLike(a) || namesOnly
                    || (speaker != nil && a.dictionaryWords >= 1) else { continue }
            let rect = union(block.map { $0.rect })
            let conf = block.map { $0.confidence }.min() ?? 0
            var piece = SSPiece(sourceText: rest, speaker: speaker, rect: rect, lineCount: block.count,
                                category: classify(rect: rect, wordCount: a.alphaWords, hasSpeaker: speaker != nil, text: rest),
                                confidence: conf, validRatio: a.validRatio, wordCount: a.alphaWords, rightLimit: nil)
            piece.speakerLabel = label
            piece.knownInData = known
            pieces.append(piece)
        }
        attachSpeakerLabels(labels, to: &pieces, refW: refW)
        return pieces
    }

    /// 1.20: "(Sam)" + "Creepy." bị OCR tách thành 2 mảnh -> gộp lại thành 1 câu thoại có người nói.
    /// Khung dịch phủ cả nhãn "(Sam)" và hiện "(Sam) Rùng rợn." màu vàng như mọi câu thoại khác.
    static func attachSpeakerLabels(_ labels: [(name: String, label: String, rect: CGRect)], to pieces: inout [SSPiece], refW: CGFloat) {
        for lb in labels {
            let h = lb.rect.height
            var best: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for (i, p) in pieces.enumerated() where p.speaker == nil {
                let lineH = p.rect.height / CGFloat(max(1, p.lineCount))
                let firstMidY = p.rect.minY + lineH / 2
                guard abs(firstMidY - lb.rect.midY) < max(h, lineH) * 0.6 else { continue }
                guard abs(lineH - h) < max(lineH, h) * 0.6 else { continue }
                let gapPx = (p.rect.minX - lb.rect.maxX) * refW
                guard gapPx > -h * refH * 0.5, gapPx < max(90, h * refH * 7) else { continue }
                if gapPx < bestGap { bestGap = gapPx; best = i }
            }
            guard let i = best else { continue }
            pieces[i].speaker = lb.name
            pieces[i].speakerLabel = lb.label
            pieces[i].rect = pieces[i].rect.union(lb.rect)
            pieces[i].category = .dialogue
        }
    }
}

// MARK: - Bộ nhớ dịch (Data Việt hoá .sqlite)

struct TranslationDBReport {
    var schema: String = "Chưa nạp"
    var totalRows: Int = 0
    var validPairs: Int = 0
    var identicalRows: Int = 0
    var emptyRows: Int = 0
    var namesLoaded: Int = 0

    var summary: String {
        if totalRows == 0 { return "Chưa có data Việt hoá" }
        if validPairs == 0 {
            return "⚠️ Data lỗi: \(totalRows) dòng nhưng 0 cặp Anh→Việt (\(identicalRows) dòng có bản dịch giống hệt câu gốc). App sẽ dùng dịch AI."
        }
        var s = "Data: \(validPairs) cặp Anh→Việt hợp lệ / \(totalRows) dòng"
        if identicalRows > 0 { s += " (\(identicalRows) dòng chưa dịch bị bỏ qua)" }
        return s
    }
}

final class TranslationMemory {
    private let lock = NSLock()
    private var entries: [(norm: String, tokens: [String], vi: String, en: String)] = []
    private var exact: [String: [Int]] = [:]
    private var inverted: [String: [Int]] = [:]
    /// Vị trí câu vừa khớp trong data (data giữ thứ tự kịch bản -> đoạn tiếp theo thường là câu này hoặc câu kế)
    private var lastIndex: Int = -1
    /// 1.14: Bảng ghép câu Anh ↔ câu Việt bên trong mỗi dòng data (tính khi cần)
    private var alignCache: [Int: [(tokStart: Int, tokEnd: Int, vi: String)]] = [:]

    struct Match {
        enum Kind { case exact, fuzzy, fragment }
        let vi: String
        let index: Int
        let kind: Kind
    }
    private(set) var names: Set<String> = []
    private(set) var report = TranslationDBReport()

    // ---- Chuẩn hoá (PHẢI GIỐNG tools/vietsub_db_tool.py) ----
    private static let reSpeaker = try! NSRegularExpression(pattern: "^\\s*\\[[^\\]]{1,24}\\]\\s*")
    private static let reBreak = try! NSRegularExpression(pattern: "<\\s*(cr|br)\\s*/?>", options: [.caseInsensitive])
    private static let reTag = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let rePlaceholder = try! NSRegularExpression(pattern: "\\{\\d+\\}")

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    static func normalize(_ input: String) -> String {
        var s = input.precomposedStringWithCanonicalMapping
        s = replace(reSpeaker, in: s, with: "")
        s = replace(reBreak, in: s, with: " ")
        s = replace(reTag, in: s, with: "")
        s = replace(rePlaceholder, in: s, with: " ")
        s = s.lowercased()
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
             .replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "´", with: "'")
        s = s.replacingOccurrences(of: "'", with: "")
        let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Làm sạch câu tiếng Việt để hiển thị (bỏ <Italic>, đổi <cr> thành xuống dòng)
    static func cleanDisplay(_ vi: String) -> String {
        var s = replace(reBreak, in: vi, with: "\n")
        s = replace(reTag, in: s, with: "")
        s = s.replacingOccurrences(of: "\n\n", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasVietnameseMarks(_ s: String) -> Bool {
        s.range(of: "[àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ]",
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    // ---- Nạp data ----
    @discardableResult
    func load(url: URL) -> TranslationDBReport {
        var newEntries: [(norm: String, tokens: [String], vi: String, en: String)] = []
        var newNames: Set<String> = []
        var rep = TranslationDBReport()

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let conn = db else {
            if let d = db { sqlite3_close(d) }
            install(entries: [], names: [], report: rep)
            return rep
        }
        defer { sqlite3_close(conn) }

        func query(_ sql: String, _ row: ([String?]) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
            defer { sqlite3_finalize(s) }
            let n = sqlite3_column_count(s)
            while sqlite3_step(s) == SQLITE_ROW {
                var cols: [String?] = []
                for i in 0..<n {
                    cols.append(sqlite3_column_text(s, i).map { String(cString: $0) })
                }
                row(cols)
            }
        }
        func columns(of table: String) -> [String] {
            var names: [String] = []
            query("PRAGMA table_info(\"\(table)\")") { cols in
                if cols.count > 1, let n = cols[1] { names.append(n) }
            }
            return names
        }

        var tables: [String] = []
        query("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'") { c in
            if let n = c.first ?? nil { tables.append(n) }
        }

        // Chọn bảng + cột Anh/Việt
        let enAliases = ["en", "english", "en_raw", "original_text", "original", "source", "source_text", "text_raw", "text_en"]
        let viAliases = ["vi", "vietnamese", "vi_text", "translated_text", "translation", "target", "target_text", "text_vi"]
        var chosen: (table: String, en: String, vi: String)?
        let preferred = ["translations_v2", "translations", "subtitles", "subtitles_fts"]
        let ordered = preferred.filter { tables.contains($0) } + tables.filter { !preferred.contains($0) }
        for t in ordered where !t.hasSuffix("_data") && !t.hasSuffix("_idx") && !t.hasSuffix("_content")
            && !t.hasSuffix("_docsize") && !t.hasSuffix("_config") && t != "glossary" && t != "meta" {
            let cols = columns(of: t).map { $0.lowercased() }
            if let e = enAliases.first(where: { cols.contains($0) }), let v = viAliases.first(where: { cols.contains($0) }) {
                chosen = (t, e, v)
                break
            }
        }

        if let c = chosen {
            rep.schema = "\(c.table)(\(c.en) → \(c.vi))"
            let ordered = "SELECT \"\(c.en)\", \"\(c.vi)\" FROM \"\(c.table)\" ORDER BY rowid"
            let plain = "SELECT \"\(c.en)\", \"\(c.vi)\" FROM \"\(c.table)\""
            var useSQL = ordered
            var probe: OpaquePointer?
            if sqlite3_prepare_v2(conn, ordered, -1, &probe, nil) != SQLITE_OK { useSQL = plain }
            sqlite3_finalize(probe)
            query(useSQL) { cols in
                rep.totalRows += 1
                guard let en = cols[0] ?? nil, let vi = cols.count > 1 ? cols[1] : nil, !en.isEmpty, !vi.isEmpty else {
                    rep.emptyRows += 1
                    return
                }
                let n = Self.normalize(en)
                let nv = Self.normalize(vi)
                guard !n.isEmpty else { rep.emptyRows += 1; return }
                if n == nv || (Self.hasVietnameseMarks(en) && !Self.hasVietnameseMarks(vi)) {
                    rep.identicalRows += 1
                    return
                }
                let toks = n.split(separator: " ").map(String.init)
                newEntries.append((n, toks, Self.cleanDisplay(vi), en))
            }
        }
        rep.validPairs = newEntries.count

        if tables.contains("glossary") {
            let cols = columns(of: "glossary").map { $0.lowercased() }
            if cols.contains("term") {
                query("SELECT term FROM glossary") { c in
                    if let t = c.first ?? nil {
                        for w in t.lowercased().split(separator: " ") { newNames.insert(String(w)) }
                    }
                }
            }
        }
        rep.namesLoaded = newNames.count
        install(entries: newEntries, names: newNames, report: rep)
        return rep
    }

    private func install(entries newEntries: [(norm: String, tokens: [String], vi: String, en: String)], names: Set<String>, report rep: TranslationDBReport) {
        var ex: [String: [Int]] = [:]
        var inv: [String: [Int]] = [:]
        for (i, e) in newEntries.enumerated() {
            ex[e.norm, default: []].append(i)
            for t in Set(e.tokens) where t.count >= 3 {
                inv[t, default: []].append(i)
            }
        }
        lock.lock()
        entries = newEntries
        exact = ex
        inverted = inv
        lastIndex = -1
        alignCache.removeAll()
        self.names = names
        report = rep
        lock.unlock()
    }

    /// Chữ này có nguyên văn trong data không (dùng để chắc chắn không phải chữ rác)
    func containsExact(_ english: String) -> Bool {
        let n = Self.normalize(english)
        guard !n.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return exact[n] != nil
    }

    // ---- Tra cứu ----
    func lookup(_ english: String) -> String? { lookupMatch(english)?.vi }

    /// 1.13: Khớp câu với data theo 3 mức:
    ///  1. Nguyên văn (ưu tiên bản ở ngay sau câu vừa khớp nếu data có câu trùng)
    ///  2. Gần đúng (OCR sai vài ký tự)
    ///  3. ĐOẠN CÂU: game chia câu dài thành nhiều đoạn hiện lần lượt ("…all by yourself?")
    ///     -> tìm câu trong data chứa liền mạch đoạn đó, ưu tiên câu vừa khớp / câu kế tiếp.
    func lookupMatch(_ english: String) -> Match? {
        let n = Self.normalize(english)
        guard !n.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return nil }
        let last = lastIndex

        if let list = exact[n], let first = list.first {
            let idx = list.first(where: { $0 >= last && $0 <= last + 4 }) ?? first
            lastIndex = idx
            return Match(vi: entries[idx].vi, index: idx, kind: .exact)   // khớp nguyên dòng -> dịch nguyên dòng
        }

        let q = n.split(separator: " ").map(String.init)
        var counts: [Int: Int] = [:]
        for t in Set(q) where t.count >= 3 {
            if let list = inverted[t], list.count < 6000 {
                for i in list { counts[i, default: 0] += 1 }
            }
        }
        var candidates = counts.sorted { $0.value > $1.value }.prefix(80).map { $0.key }
        if last >= 0 {
            for k in 0...3 where last + k < entries.count { candidates.append(last + k) }
        }
        var seen = Set<Int>()
        candidates = candidates.filter { seen.insert($0).inserted }

        // 2. Gần đúng cả câu
        if q.count >= 2 {
            var best: (score: Double, idx: Int) = (0, -1)
            for idx in candidates {
                let sc = Self.similarity(q, entries[idx].tokens)
                if sc > best.score { best = (sc, idx) }
            }
            if best.idx >= 0 && best.score >= 0.80 {
                lastIndex = best.idx
                // Gần đúng nhưng chỉ là phần lớn của dòng dài -> vẫn chỉ lấy các câu tương ứng
                let ct = entries[best.idx].tokens
                if ct.count > q.count + 2, let start = Self.bestWindowStart(q, in: ct) {
                    return Match(vi: sentenceSlice(best.idx, start: start, length: q.count), index: best.idx, kind: .fuzzy)
                }
                return Match(vi: entries[best.idx].vi, index: best.idx, kind: .fuzzy)
            }
        }

        // 3. Đoạn câu liền mạch
        var bestFrag: (idx: Int, len: Int)?
        var fragTranslations = Set<String>()
        var fragStart: [Int: Int] = [:]
        for idx in candidates {
            let ct = entries[idx].tokens
            guard ct.count > q.count, let start = Self.runStart(q, in: ct) else { continue }
            let continuity = last >= 0 && idx >= last && idx <= last + 3
            if continuity && (q.count >= 2 || (q.first?.count ?? 0) >= 4) {
                lastIndex = idx
                return Match(vi: sentenceSlice(idx, start: start, length: q.count), index: idx, kind: .fragment)
            }
            fragStart[idx] = start
            fragTranslations.insert(entries[idx].vi)
            if bestFrag == nil || ct.count < bestFrag!.len { bestFrag = (idx, ct.count) }
        }
        if let b = bestFrag {
            let unique = fragTranslations.count == 1
            let ratio = Double(q.count) / Double(b.len)
            let ok = q.count >= 5
                || (q.count >= 3 && (unique || ratio >= 0.3))
                || (q.count == 2 && unique && b.len <= 30)
            if ok {
                lastIndex = b.idx
                return Match(vi: sentenceSlice(b.idx, start: fragStart[b.idx] ?? 0, length: q.count), index: b.idx, kind: .fragment)
            }
        }

        // OCR sai vài từ giữa đoạn: phủ ≥ 90% từ
        if q.count >= 4, let first = candidates.first {
            let cand = entries[first].tokens
            let covered = Double(q.filter { w in cand.contains(where: { Self.tokenEqual(w, $0) }) }.count) / Double(q.count)
            if covered >= 0.9 && Double(cand.count) <= Double(q.count) * 3 {
                lastIndex = first
                let start = Self.bestWindowStart(q, in: cand) ?? 0
                return Match(vi: sentenceSlice(first, start: start, length: q.count), index: first, kind: .fragment)
            }
        }
        return nil
    }

    /// Vị trí (chỉ số từ) mà các từ của q xuất hiện LIỀN MẠCH trong c (cho phép 1 từ OCR sai nếu đoạn ≥ 5 từ)
    static func runStart(_ q: [String], in c: [String]) -> Int? {
        guard !q.isEmpty, c.count >= q.count else { return nil }
        let allowedMiss = q.count >= 5 ? 1 : 0
        for start in 0...(c.count - q.count) {
            var miss = 0
            var ok = true
            for k in 0..<q.count where !tokenEqual(q[k], c[start + k]) {
                miss += 1
                if miss > allowedMiss { ok = false; break }
            }
            if ok { return start }
        }
        return nil
    }

    static func containsRun(_ q: [String], in c: [String]) -> Bool { runStart(q, in: c) != nil }

    /// Cửa sổ trong c khớp nhiều từ của q nhất (cho trường hợp OCR sai nhiều từ)
    static func bestWindowStart(_ q: [String], in c: [String]) -> Int? {
        guard !q.isEmpty, c.count >= q.count else { return nil }
        var best = (score: -1, start: 0)
        for start in 0...(c.count - q.count) {
            var sc = 0
            for k in 0..<q.count where tokenEqual(q[k], c[start + k]) { sc += 1 }
            if sc > best.score { best = (sc, start) }
        }
        return best.start
    }

    // ---- 1.14: Tách câu + ghép câu Anh ↔ Việt trong 1 dòng data ----
    private static let reSentence = try! NSRegularExpression(pattern: "(?<=[.!?…])[\"”’)\\]]*\\s+")

    static func splitSentences(_ text: String) -> [String] {
        let t = replace(reTag, in: text, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        var cursor = t.startIndex
        for m in reSentence.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            let piece = String(t[cursor..<r.lowerBound]) + String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(piece.trimmingCharacters(in: .whitespaces)) }
            cursor = r.upperBound
        }
        let rest = String(t[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }

    /// Ghép nhóm câu Anh với nhóm câu Việt theo độ dài (kiểu Gale-Church): 1-1, 1-2, 2-1, 2-2...
    static func alignSentences(_ en: [String], _ vi: [String]) -> [(en: [Int], vi: [Int])] {
        let n = en.count, m = vi.count
        guard n > 0, m > 0 else { return [] }
        let le = en.map { Double(max(1, $0.count)) }, lv = vi.map { Double(max(1, $0.count)) }
        let ratio = lv.reduce(0, +) / le.reduce(0, +)
        let inf = 1e18
        var D = [[Double]](repeating: [Double](repeating: inf, count: m + 1), count: n + 1)
        var B = [[(Int, Int)]](repeating: [(Int, Int)](repeating: (0, 0), count: m + 1), count: n + 1)
        D[0][0] = 0
        let moves: [(Int, Int, Double)] = [(1, 1, 0), (1, 2, 0.6), (2, 1, 0.6), (1, 0, 3), (0, 1, 3), (2, 2, 1.2), (1, 3, 1.5), (3, 1, 1.5)]
        for i in 0...n {
            for j in 0...m where D[i][j] < inf {
                for (a, b, pen) in moves where i + a <= n && j + b <= m {
                    var cost = pen
                    if a > 0 && b > 0 {
                        let x = le[i..<(i + a)].reduce(0, +) * ratio
                        let y = lv[j..<(j + b)].reduce(0, +)
                        cost += abs(log(y / x)) * 2
                    }
                    if D[i][j] + cost < D[i + a][j + b] {
                        D[i + a][j + b] = D[i][j] + cost
                        B[i + a][j + b] = (a, b)
                    }
                }
            }
        }
        var i = n, j = m
        var groups: [(en: [Int], vi: [Int])] = []
        while i > 0 || j > 0 {
            let (a, b) = B[i][j]
            if a == 0 && b == 0 { break }
            groups.append((Array((i - a)..<i), Array((j - b)..<j)))
            i -= a; j -= b
        }
        return groups.reversed()
    }

    /// Các nhóm câu của dòng data idx: khoảng chỉ số từ (theo en_norm) + câu Việt tương ứng
    private func sentenceGroups(_ idx: Int) -> [(tokStart: Int, tokEnd: Int, vi: String)] {
        if let cached = alignCache[idx] { return cached }
        let e = entries[idx]
        let enS = Self.splitSentences(e.en)
        let viS = Self.splitSentences(e.vi)
        var result: [(tokStart: Int, tokEnd: Int, vi: String)] = []
        if enS.count <= 1 || viS.isEmpty {
            result = [(0, e.tokens.count, e.vi)]
        } else {
            let tokCounts = enS.map { Self.normalize($0).split(separator: " ").count }
            var starts: [Int] = []
            var acc = 0
            for c in tokCounts { starts.append(acc); acc += c }
            for g in Self.alignSentences(enS, viS) {
                let viText = g.vi.map { viS[$0] }.joined(separator: " ")
                if let f = g.en.first, let l = g.en.last {
                    result.append((starts[f], starts[l] + tokCounts[l], viText))
                } else if let lastIdx = result.indices.last {
                    // câu Việt thừa -> nối vào nhóm trước
                    result[lastIdx].vi += " " + viText
                }
            }
            if result.isEmpty { result = [(0, e.tokens.count, e.vi)] }
        }
        alignCache[idx] = result
        return result
    }

    /// Chỉ lấy (các) câu Việt tương ứng với đoạn tiếng Anh đang hiện [start, start+length)
    private func sentenceSlice(_ idx: Int, start: Int, length: Int) -> String {
        let groups = sentenceGroups(idx)
        guard groups.count > 1 else { return entries[idx].vi }
        let end = start + max(1, length)
        let hit = groups.filter { $0.tokStart < end && $0.tokEnd > start }
        guard !hit.isEmpty else { return entries[idx].vi }
        return hit.map { $0.vi }.joined(separator: " ")
    }

    static func tokenEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 5 && b.count >= 5 && abs(a.count - b.count) <= 1 { return levenshtein(a, b) <= 1 }
        return false
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var used = [Bool](repeating: false, count: b.count)
        var common = 0
        for x in a {
            if let j = b.indices.first(where: { !used[$0] && tokenEqual(x, b[$0]) }) {
                used[j] = true
                common += 1
            }
        }
        return 2.0 * Double(common) / Double(a.count + b.count)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where i <= x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...max(1, y.count) where j <= y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}

// MARK: - Dịch AI online (dự phòng) - GIỮ NGUYÊN TÊN RIÊNG

final class OnlineFallbackTranslator {
    static let shared = OnlineFallbackTranslator()
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var pending: Set<String> = []
    private let cacheURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // 1.24: đổi tên file -> bỏ toàn bộ bản dịch cũ đã lưu (có câu bị mất tên "Sam")
        return docs.appendingPathComponent("ai_translation_cache_v124.json")
    }()
    private var dirty = false

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = dict
        }
    }

    func cached(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// 1.24: xoá bản dịch đã lưu (bị thiếu tên riêng) để dịch lại
    func forget(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if cache.removeValue(forKey: key) != nil { dirty = true }
    }

    /// Gửi dịch; protectedWords = tên riêng giữ nguyên. completion chạy ở luồng nền.
    func request(text: String, key: String, protectedWords: [String], completion: @escaping (String) -> Void) {
        lock.lock()
        if pending.contains(key) || cache[key] != nil { lock.unlock(); return }
        pending.insert(key)
        lock.unlock()

        // Thay tên riêng bằng mã giữ chỗ để máy dịch không dịch tên
        var working = text
        var slots: [(String, String)] = []
        for (i, word) in protectedWords.enumerated() {
            let token = "ZQX\(i)Q"
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            if working.range(of: pattern, options: .regularExpression) != nil {
                working = working.replacingOccurrences(of: pattern, with: token, options: .regularExpression)
                slots.append((token, word))
            }
        }

        guard let encoded = working.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&q=\(encoded)") else {
            finish(key: key, value: nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let parts = json.first as? [[Any]] else {
                self.finish(key: key, value: nil)
                return
            }
            var vi = parts.compactMap { $0.first as? String }.joined()
            for (token, word) in slots {
                // Google đôi khi chèn khoảng trắng / đổi hoa thường trong mã: "ZQX 0 Q", "zqx0q"
                let loose = token.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
                vi = vi.replacingOccurrences(of: loose, with: word, options: [.regularExpression, .caseInsensitive])
            }
            // 1.24: Google làm MẤT mã giữ chỗ -> chèn lại tên
            vi = SmartSubtitleEngine.reinsertNames(slots.map { $0.1 }, source: text, vi: vi)
            vi = vi.trimmingCharacters(in: .whitespacesAndNewlines)
            self.finish(key: key, value: vi.isEmpty ? nil : vi)
            if !vi.isEmpty { completion(vi) }
        }.resume()
    }

    private func finish(key: String, value: String?) {
        lock.lock()
        pending.remove(key)
        if let v = value {
            cache[key] = v
            dirty = true
        }
        let shouldSave = dirty && cache.count % 10 == 0
        let snapshot = shouldSave ? cache : [:]
        if shouldSave { dirty = false }
        lock.unlock()
        if shouldSave, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    func store(key: String, value: String) {
        lock.lock()
        cache[key] = value
        dirty = true
        lock.unlock()
    }

    func persist() {
        lock.lock()
        let snapshot = cache
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

// MARK: - Lấy màu chữ / màu nền thật từ khung hình

enum StyleSampler {
    static func sample(frame: CGImage, rect: CGRect) -> SSStyle {
        let W = CGFloat(frame.width), H = CGFloat(frame.height)
        let px = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard px.width >= 4, px.height >= 4, let crop = frame.cropping(to: px) else { return .fallback }

        let sw = max(8, min(120, Int(px.width / 2)))
        let sh = max(4, min(40, Int(px.height / 2)))
        var buf = [UInt8](repeating: 0, count: sw * sh * 4)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            return true
        }
        guard drawn else { return .fallback }

        let n = sw * sh
        var lum = [Double](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = l
            hist[min(255, Int(l))] += 1
        }
        // Ngưỡng Otsu tách 2 lớp: chữ / nền
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = n - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        var hi = (0.0, 0.0, 0.0, 0), lo = (0.0, 0.0, 0.0, 0)
        for i in 0..<n {
            let r = Double(buf[i * 4]) / 255, g = Double(buf[i * 4 + 1]) / 255, b = Double(buf[i * 4 + 2]) / 255
            if lum[i] > Double(threshold) { hi = (hi.0 + r, hi.1 + g, hi.2 + b, hi.3 + 1) }
            else { lo = (lo.0 + r, lo.1 + g, lo.2 + b, lo.3 + 1) }
        }
        guard hi.3 > 0, lo.3 > 0 else { return .fallback }
        let hiC = (hi.0 / Double(hi.3), hi.1 / Double(hi.3), hi.2 / Double(hi.3))
        let loC = (lo.0 / Double(lo.3), lo.1 / Double(lo.3), lo.2 / Double(lo.3))
        // Chữ thường chiếm ít điểm ảnh hơn nền
        let textIsBright = hi.3 <= lo.3
        let textFrac = Double(textIsBright ? hi.3 : lo.3) / Double(n)
        let textC = textIsBright ? hiC : loC
        let bgC = textIsBright ? loC : hiC
        let lt = SSStyle.luminance(textC), lb = SSStyle.luminance(bgC)
        var style = SSStyle(textRGB: textC, backgroundRGB: bgC, isBold: textFrac > 0.22)
        // Tương đối (không dùng ngưỡng sáng tuyệt đối): cảnh đêm tờ giấy rất tối nhưng mực vẫn tối hơn giấy
        style.darkOnLight = !textIsBright && (lb - lt) >= 0.05 && lb >= lt * 1.5
        return style
    }

    /// 1.17: Chữ nằm trên TỜ GIẤY / THƯ / BIỂN BÁO: mực tối trên nền sáng, và vùng xung quanh khối chữ
    /// cũng là mặt nền sáng đồng màu (mặt giấy). Chữ giao diện game thường là chữ sáng trên nền tối.
    static func isPaperText(frame: CGImage, rect: CGRect, style: SSStyle) -> Bool {
        guard style.darkOnLight else { return false }
        let padX = max(0.02, rect.width * 0.12), padY = max(0.02, rect.height * 0.6)
        let ring = rect.insetBy(dx: -padX, dy: -padY).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let around = sample(frame: frame, rect: ring)
        // Vùng mở rộng (mặt giấy quanh chữ) vẫn có phần tối chiếm thiểu số và tối hơn hẳn phần nền
        let la = SSStyle.luminance(around.backgroundRGB), lt = SSStyle.luminance(around.textRGB)
        return la >= lt * 1.3 && (la - lt) >= 0.04
    }

    /// Ảnh xám rất nhỏ của vùng chữ để phát hiện chữ gốc đã biến mất
    static func thumbnail(frame: CGImage, rect: CGRect) -> [UInt8] {
        let W = CGFloat(frame.width), H = CGFloat(frame.height)
        let px = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard px.width >= 4, px.height >= 4, let crop = frame.cropping(to: px) else { return [] }
        let tw = 24, th = 6
        var buf = [UInt8](repeating: 0, count: tw * th)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: tw, height: th))
            return true
        }
        return drawn ? buf : []
    }

    static func thumbDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    static func hex(_ c: (Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int(max(0, min(1, c.0)) * 255), Int(max(0, min(1, c.1)) * 255), Int(max(0, min(1, c.2)) * 255))
    }
}

// MARK: - Theo dõi khung chữ ổn định (không nhảy, không chớp tắt)

final class TrackedPiece {
    let id: String
    let createdOrder: Int
    var key: String
    var piece: SSPiece
    var translation: String?
    var fromDatabase = false
    var dbIndex: Int = -1
    var aiPending = false
    var hits = 1
    var misses = 0
    var thumb: [UInt8] = []
    var style: SSStyle = .fallback
    /// Lúc bản dịch bắt đầu hiện / lúc chữ gốc biến mất
    var shownAt: Date?
    var goneAt: Date?
    /// Cỡ chữ đã khoá (menu, nhiệm vụ) để không nhảy to nhỏ
    var lockedFontPx: CGFloat?
    /// Khoá chữ đã gửi AI (OCR có thể đọc hơi khác ở lần sau)
    var requestKey: String?
    /// 1.16: số lần chữ DI CHUYỂN theo máy quay (chữ trên vật phẩm / biển báo trong game)
    var moveEvents = 0
    /// 1.17: chữ in trên giấy / thư / biển báo (mực tối trên nền sáng)
    var isPaper = false

    /// Chữ dính vào vật thể 3D: di chuyển ở phần lớn các lần quét -> không dịch
    var isWorldText: Bool {
        guard piece.category != .dialogue, piece.speaker == nil else { return false }
        if isPaper { return true }
        guard !piece.knownInData else { return false }
        return moveEvents >= 1 && moveEvents * 2 >= max(1, hits - 1)
    }

    init(id: String, order: Int, key: String, piece: SSPiece) {
        self.id = id
        self.createdOrder = order
        self.key = key
        self.piece = piece
    }

    /// 1.20: cảnh game đã chuyển (cắt cảnh) -> khung này không còn liên quan, tắt ngay không giữ thêm
    var sceneCut = false

    var requiredHits: Int {
        if fromDatabase || piece.knownInData { return 1 }
        // 1.20: lời thoại có người nói "(Sam) Creepy." -> hiện ngay
        if piece.speaker != nil && piece.confidence >= 0.5 { return 1 }
        // 1.20: chữ ngoài phụ đề, không có trong data, OCR chưa chắc chắn (chữ viết tay trên bảng, hoạ tiết)
        // -> phải đọc được ở 2 lần quét, đứng yên (chữ trôi theo máy quay sẽ bị coi là chữ trên vật thể)
        if piece.category != .dialogue && piece.confidence < 0.95 { return 2 }
        if piece.validRatio >= 0.99 && piece.wordCount >= 1 && piece.wordCount <= 4 && piece.confidence >= 0.5 {
            return piece.wordCount == 1 ? 2 : 1          // lựa chọn câu trả lời / menu ngắn
        }
        if piece.confidence >= 0.8 && piece.validRatio >= 0.85 && piece.wordCount >= 3 { return 1 }
        return 2
    }

    var isConfirmed: Bool { hits >= requiredHits }

    /// 1.13: Giữ chữ dịch sau khi chữ gốc biến mất.
    /// - Data Việt hoá: hiện gần như tức thì -> chỉ giữ 0,35 giây (che khoảng trống giữa 2 đoạn phụ đề).
    /// - Dịch AI: về chậm hơn -> giữ đủ thời gian đọc (1,6 - 4,5 giây tuỳ độ dài).
    func holdUntil() -> Date? {
        guard let gone = goneAt else { return nil }
        if sceneCut { return gone }
        // 1.20: bản dịch về SAU khi chữ gốc đã biến mất (AI chậm, đã qua cảnh khác) -> không hiện.
        // Đây là lỗi hiện "CỐT TRUYỆN CỦA CHÚNG TA" ở cảnh không có chữ tiếng Anh nào.
        // Riêng lời thoại ngắn: AI về trễ dưới 1,5 giây vẫn hiện (nhường chỗ ngay khi có câu thoại mới).
        guard let shown = shownAt else { return gone }
        if shown > gone {
            guard piece.category == .dialogue, shown.timeIntervalSince(gone) < 1.5 else { return gone }
        }
        if fromDatabase { return gone.addingTimeInterval(0.35) }
        let chars = Double(translation?.count ?? 0)
        let readTime = min(4.5, max(1.6, 0.8 + chars * 0.05))
        return max(gone.addingTimeInterval(1.2), shown.addingTimeInterval(readTime))
    }

    func isVisible(at now: Date) -> Bool {
        guard translation != nil, isConfirmed, !isWorldText, !sceneCut else { return false }
        if let until = holdUntil() { return now < until }
        return true
    }
}

/// 1.13: Giữ cỡ chữ + vị trí dòng thoại ổn định (trung vị nhiều lần đo, chỉ đổi khi khác hẳn)
final class LayoutStabilizer {
    private var fontHistory: [CGFloat] = []
    private var bottomHistory: [CGFloat] = []
    private(set) var dialogueFontPx: CGFloat?
    private(set) var dialogueBottomPx: CGFloat?

    func observeDialogue(fontPx: CGFloat, bottomPx: CGFloat) {
        fontHistory.append(fontPx)
        if fontHistory.count > 15 { fontHistory.removeFirst() }
        bottomHistory.append(bottomPx)
        if bottomHistory.count > 9 { bottomHistory.removeFirst() }
        let mf = Self.median(fontHistory)
        if let cur = dialogueFontPx {
            // 1.14: chỉ đổi cỡ khi phụ đề game thật sự đổi cỡ (lệch > 25% trên ít nhất 5 lần đo)
            if fontHistory.count >= 5 && abs(mf - cur) / cur > 0.25 { dialogueFontPx = mf.rounded() }
        } else {
            dialogueFontPx = mf.rounded()
        }
        let mb = Self.median(bottomHistory)
        if let cur = dialogueBottomPx {
            if abs(mb - cur) > 14 { dialogueBottomPx = mb.rounded() }
        } else {
            dialogueBottomPx = mb.rounded()
        }
    }

    func reset() {
        fontHistory.removeAll()
        bottomHistory.removeAll()
        dialogueFontPx = nil
        dialogueBottomPx = nil
    }

    static func median(_ v: [CGFloat]) -> CGFloat {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

// MARK: - Bố cục khung dịch

enum SubtitleLayoutEngine {
    static let refH: CGFloat = 720
    static let dialogueYellow = (1.0, 0.86, 0.10)
    static let black = (0.0, 0.0, 0.0)

    static func measure(_ text: String, fontPx: CGFloat, width: CGFloat) -> CGSize {
        let font = UIFont.systemFont(ofSize: fontPx, weight: .bold)
        let b = (text as NSString).boundingRect(
            with: CGSize(width: max(10, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return CGSize(width: ceil(b.width), height: ceil(b.height))
    }

    static func layout(_ items: [TrackedPiece], refW: CGFloat = 1280, stabilizer: LayoutStabilizer) -> [TranslatedBox] {
        var out: [TranslatedBox] = []
        for item in items {
            guard let vi = item.translation else { continue }
            let p = item.piece
            let display = p.speakerLabel.map { "\($0) \(vi)" } ?? vi
            let o = CGRect(x: p.rect.minX * refW, y: p.rect.minY * refH, width: p.rect.width * refW, height: p.rect.height * refH)
            let observedFont = max(10, min(64, o.height / CGFloat(max(1, p.lineCount)) * 0.80))

            var boxRect: CGRect
            var fontPx: CGFloat
            var centered = false

            if p.category == .dialogue {
                // ---- Lời thoại: cỡ chữ + đáy dòng cố định, căn giữa, mọc lên trên ----
                // 1.16: chỉ dùng cỡ chữ / đáy dòng cố định khi chữ nằm đúng vùng phụ đề quen thuộc
                if let f = stabilizer.dialogueFontPx, abs(f - observedFont) / observedFont < 0.35 {
                    fontPx = f
                } else {
                    fontPx = observedFont
                }
                let padX = fontPx * 0.35, padY = fontPx * 0.18
                let cx = abs(p.rect.midX - 0.5) < 0.12 ? refW / 2 : o.midX
                let maxW = min(refW * 0.9, 2 * (min(cx, refW - cx) - 6))
                let size = measure(display, fontPx: fontPx, width: maxW - padX * 2)
                let boxW = min(maxW, max(size.width * 1.04 + padX * 2 + 2, o.width + padX * 2))
                let lineHpx = o.height / CGFloat(max(1, p.lineCount))
                var bottom = o.maxY + padY
                if let sb = stabilizer.dialogueBottomPx, abs(sb - o.maxY) < lineHpx * 1.2 { bottom = sb + padY }
                bottom = max(bottom, o.maxY + padY)
                let boxH = max(size.height + padY * 2, bottom - (o.minY - padY))
                boxRect = CGRect(x: cx - boxW / 2, y: bottom - boxH, width: boxW, height: boxH)
                centered = true
            } else {
                // ---- Menu / lựa chọn / nhiệm vụ: neo góc trái-trên chữ gốc, khoá cỡ chữ ----
                if let locked = item.lockedFontPx, abs(observedFont - locked) / locked <= 0.2 {
                    fontPx = locked
                } else {
                    fontPx = observedFont
                    item.lockedFontPx = observedFont
                }
                let padX = fontPx * 0.32, padY = fontPx * 0.14
                let originX = o.minX - padX, originY = o.minY - padY
                let minW = o.width + padX * 2, minH = o.height + padY * 2

                var rightLimit = refW - 4
                if let r = p.rightLimit { rightLimit = min(rightLimit, r * refW) }
                var bottomLimit = refH - 2
                for other in items where other !== item {
                    let r = other.piece.rect
                    let vOverlap = min(r.maxY, p.rect.maxY) - max(r.minY, p.rect.minY) > 0
                    if vOverlap && r.minX >= p.rect.maxX - 0.002 { rightLimit = min(rightLimit, r.minX * refW - 3) }
                    let hOverlap = min(r.maxX, p.rect.maxX) - max(r.minX, p.rect.minX) > 0
                    if hOverlap && r.minY >= p.rect.maxY - 0.002 { bottomLimit = min(bottomLimit, r.minY * refH - 2) }
                }
                let maxW = max(minW, rightLimit - originX)
                let maxH = max(minH, bottomLimit - originY)
                var scale: CGFloat = 1.0
                var size = CGSize.zero
                while true {
                    size = measure(display, fontPx: fontPx * scale, width: maxW - padX * 2)
                    if size.height + padY * 2 <= maxH + 1 || scale <= 0.7 { break }
                    scale -= 0.1
                }
                fontPx *= scale
                let boxW = min(maxW, max(minW, size.width * 1.04 + padX * 2 + 2))
                let boxH = max(minH, size.height + padY * 2)
                boxRect = CGRect(x: originX, y: originY, width: boxW, height: boxH)
            }

            let textRGB: (Double, Double, Double)
            if p.category == .dialogue {
                textRGB = dialogueYellow
            } else {
                let c = item.style.textRGB
                let lum = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
                textRGB = lum >= 0.55 ? c : (1, 1, 1)   // nền luôn đen -> chữ tối đổi sang trắng
            }

            var box = TranslatedBox(
                text: display,
                x: Double(boxRect.minX / refW), y: Double(boxRect.minY / refH),
                w: Double(boxRect.width / refW), h: Double(boxRect.height / refH),
                category: p.category.rawValue,
                isAITranslated: !item.fromDatabase
            )
            box.stableID = item.id
            box.fontSizeNorm = Double(fontPx / refH)
            box.textColorHex = StyleSampler.hex(textRGB)
            box.backgroundColorHex = StyleSampler.hex(black)
            box.isBold = true
            box.textAlignCenter = centered
            out.append(box)
        }
        return out
    }
}

// MARK: - Bộ máy tổng

final class SmartSubtitleEngine {
    let memory = TranslationMemory()
    let online = OnlineFallbackTranslator.shared
    private let filter = GameTextFilter()
    private let ocr = SmartOCREngine()
    private let queue = DispatchQueue(label: "ps5translator.smartsubtitle", qos: .userInitiated)
    private var tracked: [TrackedPiece] = []
    private var nextID = 1
    private var lastFrame: CGImage?
    private var busy = false
    private let stabilizer = LayoutStabilizer()

    var useOnlineAI = true
    /// Bộ dịch AI (Apple Intelligence trên máy / Google online)
    var engineMode: TranslationEngineMode = .appleThenGoogle
    /// Tên game đang chơi (ngữ cảnh cho AI)
    var gameTitle: String = ""
    /// 1.17: không dịch chữ trên giấy / thư / biển báo (mực tối trên nền sáng)
    var skipPaperText = true
    private var frameRefW: CGFloat = 1280
    private var recentDialogue: [String] = []
    /// 1.20: ảnh xám thu nhỏ của cả khung hình lần quét trước (phát hiện cắt cảnh)
    private var lastSceneThumb: [UInt8] = []

    /// 1.20: chữ nằm đúng dòng phụ đề quen thuộc (cùng đáy dòng, cùng cỡ chữ, gần giữa màn hình)
    /// -> là lời thoại kể cả khi chỉ 1-2 từ ("Creepy.") hoặc OCR tách mất tên người nói
    private func isSubtitleZone(_ p: SSPiece) -> Bool {
        guard let sb = stabilizer.dialogueBottomPx, let sf = stabilizer.dialogueFontPx else { return false }
        guard !Self.isAllCaps(p.sourceText), p.rightLimit == nil else { return false }
        let refH = SubtitleLayoutEngine.refH
        let lineH = p.rect.height * refH / CGFloat(max(1, p.lineCount))
        let font = lineH * 0.80
        guard abs(font - sf) / sf < 0.3 else { return false }
        guard abs(p.rect.maxY * refH - sb) < lineH * 1.3 else { return false }
        return abs(p.rect.midX - 0.5) < 0.3 && p.rect.midY >= 0.6
    }
    /// Gọi khi bản dịch AI về muộn -> cập nhật khung ngay không đợi lần quét sau
    var onAsyncUpdate: (([TranslatedBox]) -> Void)?
    /// 1.19: Log quét chữ cho màn hình chính (DATA / AI / RÁC). Gọi trên luồng nền.
    var onScanLog: (([ScanLogItem]) -> Void)?
    /// 1.19: Tên riêng trong data Việt hoá đang dùng (giữ nguyên khi dịch)
    var knownNames: [String] { memory.names.sorted() }

    func loadDatabase(url: URL) -> TranslationDBReport {
        let rep = memory.load(url: url)
        queue.async {
            self.filter.extraNames = self.memory.names
            self.tracked.removeAll()
            self.stabilizer.reset()
        }
        return rep
    }

    var isBusy: Bool { busy }

    /// Xử lý 1 khung hình. completion trên luồng nền: (các khung dịch, chữ gốc tóm tắt)
    func process(frame: CGImage, cropped: CGImage, roi: CGRect, completion: @escaping ([TranslatedBox], String) -> Void) {
        busy = true
        queue.async {
            defer { self.busy = false }
            self.lastFrame = frame
            // Hệ toạ độ tham chiếu cao 720, rộng theo tỉ lệ khung hình (YouTube có video dọc / vuông)
            self.frameRefW = 720 * CGFloat(frame.width) / CGFloat(max(1, frame.height))
            let names = Array(GameVocabulary.builtInNames.union(self.memory.names)).map { $0.capitalized }
            let lines = self.ocr.recognize(cropped: cropped, roi: roi, customWords: names)
            let memory = self.memory
            let pieces = PieceBuilder.buildPieces(lines: lines, filter: self.filter, refW: self.frameRefW,
                                                  isKnownText: { memory.containsExact($0) })
            self.updateTracking(with: pieces, frame: frame)
            let visible = self.visibleItems(now: Date())
            let boxes = SubtitleLayoutEngine.layout(visible, refW: self.frameRefW, stabilizer: self.stabilizer)
            let present = self.tracked.filter { $0.goneAt == nil }
            let summary: String
            if present.isEmpty {
                summary = lines.isEmpty ? "Màn hình không có chữ" : "Đã lọc \(lines.count) dòng chữ rác / chưa cần dịch"
            } else {
                summary = present.map { t in
                    let src = t.translation == nil ? (t.aiPending ? "⏳AI" : "✗") : (t.fromDatabase ? "📗Data" : "🤖AI")
                    return "\(src) \(t.piece.sourceText)"
                }.joined(separator: " | ")
            }
            if let logCB = self.onScanLog {
                logCB(self.buildScanLog(lines: lines, pieces: pieces, present: present))
            }
            completion(boxes, summary)
        }
    }

    /// 1.19: Gom kết quả 1 lần quét thành các dòng log: câu khớp data, câu dịch AI, chữ rác bị bỏ qua (kèm lý do)
    private func buildScanLog(lines: [SSLine], pieces: [SSPiece], present: [TrackedPiece]) -> [ScanLogItem] {
        var items: [ScanLogItem] = []
        for t in present {
            let src = t.piece.sourceText
            if t.isPaper {
                items.append(ScanLogItem(key: t.key, kind: .trash, source: src, translation: nil, note: "Bỏ qua: chữ trên giấy / thư / biển báo"))
            } else if t.isWorldText {
                items.append(ScanLogItem(key: t.key, kind: .trash, source: src, translation: nil, note: "Bỏ qua: chữ dính vật thể trong game"))
            } else if let vi = t.translation {
                items.append(ScanLogItem(key: t.key, kind: t.fromDatabase ? .data : .ai, source: src, translation: vi, note: nil))
            } else if t.aiPending {
                items.append(ScanLogItem(key: t.key, kind: .pending, source: src, translation: nil, note: "AI đang dịch…"))
            } else {
                items.append(ScanLogItem(key: t.key, kind: .missing, source: src, translation: nil,
                                         note: "Không có trong data, AI đang tắt hoặc chưa dịch được"))
            }
        }
        // Dòng OCR không thành câu cần dịch = chữ rác / HUD / nút bấm
        let pieceText = pieces.map { TranslationMemory.normalize($0.sourceText) }.joined(separator: " | ")
        for line in lines {
            guard !TranslationMemory.hasVietnameseMarks(line.text) else { continue }
            let key = TranslationMemory.normalize(line.text)
            guard key.count >= 2, !pieceText.contains(key) else { continue }
            items.append(ScanLogItem(key: "trash|" + key, kind: .trash, source: line.text, translation: nil,
                                     note: "Bỏ qua: " + Self.trashReason(line)))
        }
        return items
    }

    private static func trashReason(_ line: SSLine) -> String {
        if line.confidence < 0.45 { return "OCR mờ, không chắc chữ" }
        let hPx = line.rect.height * PieceBuilder.refH
        if hPx < 7.5 { return "chữ quá nhỏ (số / HUD)" }
        if hPx > 50 { return "chữ quá to (tiêu đề / tên)" }
        if line.skewDegrees > 3.0 || line.shearRatio > 0.22 { return "chữ nghiêng trên vật thể 3D" }
        return "ký tự rác / nút bấm / tên riêng"
    }

    func reset() {
        queue.async {
            self.tracked.removeAll()
            self.stabilizer.reset()
            self.lastSceneThumb = []
        }
    }

    /// Khung đang hiện: khung đã "hết chữ gốc" (đang giữ) sẽ nhường chỗ cho câu mới ở cùng vị trí
    private func visibleItems(now: Date) -> [TrackedPiece] {
        var candidates = tracked.filter { $0.isVisible(at: now) }.sorted { $0.createdOrder > $1.createdOrder }
        // 1.17: Cùng nội dung xuất hiện 2 lần (tờ thư + bảng chữ giao diện): chỉ dịch bản chữ SÁNG (giao diện)
        if skipPaperText {
            let present = tracked.filter { $0.goneAt == nil }
            candidates.removeAll { t in
                guard t.style.darkOnLight, t.piece.category != .dialogue, t.piece.speaker == nil else { return false }
                let tk = t.key.split(separator: " ").map(String.init)
                return present.contains { o in
                    o !== t && !o.style.darkOnLight
                        && TranslationMemory.similarity(tk, o.key.split(separator: " ").map(String.init)) >= 0.6
                }
            }
        }
        var out: [TrackedPiece] = []
        for t in candidates {
            let r = t.piece.rect.insetBy(dx: -0.01, dy: -0.02)
            let conflict = out.contains { o in
                (o.piece.category == .dialogue && t.piece.category == .dialogue)
                    || o.piece.rect.insetBy(dx: -0.01, dy: -0.02).intersects(r)
            }
            if conflict && t.goneAt != nil { continue }
            out.append(t)
        }
        return out.sorted { $0.createdOrder < $1.createdOrder }
    }

    private func updateTracking(with pieces: [SSPiece], frame: CGImage) {
        let now = Date()
        var matchedIDs = Set<String>()

        // 1.20: phát hiện CẮT CẢNH (cả khung hình đổi hẳn) -> khung dịch của cảnh cũ tắt ngay
        let wholeThumb = StyleSampler.thumbnail(frame: frame, rect: CGRect(x: 0, y: 0.08, width: 1, height: 0.62))
        let isSceneCut = !lastSceneThumb.isEmpty && StyleSampler.thumbDiff(wholeThumb, lastSceneThumb) > 11   // đo trên video: cắt cảnh 16-21, máy quay lia <= 5
        lastSceneThumb = wholeThumb

        for var piece in pieces {
            let key = TranslationMemory.normalize(piece.sourceText)
            guard !key.isEmpty else { continue }
            let keyTokens = key.split(separator: " ").map(String.init)
            if piece.category != .dialogue && isSubtitleZone(piece) { piece.category = .dialogue }

            if piece.category == .dialogue {
                let lineH = piece.rect.height * SubtitleLayoutEngine.refH / CGFloat(max(1, piece.lineCount))
                stabilizer.observeDialogue(fontPx: max(10, min(64, lineH * 0.80)), bottomPx: piece.rect.maxY * SubtitleLayoutEngine.refH)
            }

            // (a) Cùng chữ / gần giống, cùng vị trí
            var bestMatch: TrackedPiece?
            var bestScore = 0.0
            for t in tracked where !matchedIDs.contains(t.id) {
                let dist = hypot(t.piece.rect.midX - piece.rect.midX, t.piece.rect.midY - piece.rect.midY)
                guard dist < max(0.06, piece.rect.height * 2.5) else { continue }
                let sim = t.key == key ? 1.0 : TranslationMemory.similarity(keyTokens, t.key.split(separator: " ").map(String.init))
                let score = sim - Double(dist)
                if sim >= 0.6 && score > bestScore { bestScore = score; bestMatch = t }
            }
            // Tra data chỉ khi chữ mới / chữ đổi (đỡ tốn CPU mỗi lần quét)
            let dbMatch: TranslationMemory.Match? = (bestMatch?.key == key) ? nil : memory.lookupMatch(piece.sourceText)
            // (b) Đoạn tiếp theo của CÙNG câu trong data -> dùng lại khung cũ (không chớp)
            if bestMatch == nil, let m = dbMatch {
                bestMatch = tracked.first { t in
                    !matchedIDs.contains(t.id) && t.dbIndex == m.index && t.piece.category == piece.category
                        && abs(t.piece.rect.midY - piece.rect.midY) < 0.2
                }
            }

            if let t = bestMatch {
                matchedIDs.insert(t.id)
                t.hits += 1
                t.misses = 0
                t.goneAt = nil
                t.sceneCut = false
                let r = t.piece.rect, n = piece.rect
                let moved = abs(r.minX - n.minX) > 0.012 || abs(r.minY - n.minY) > 0.012
                    || abs(r.width - n.width) > 0.03 || abs(r.height - n.height) > 0.02
                // Cả khối dịch chuyển (không chỉ OCR rung khung) -> chữ đang trôi theo máy quay
                if abs(r.midX - n.midX) > 0.015 && abs(r.midY - n.midY) > 0.004 || abs(r.midY - n.midY) > 0.015 {
                    t.moveEvents += 1
                }
                var updated = piece
                if !moved { updated.rect = r }   // giữ nguyên vị trí -> khung không rung
                if t.piece.speakerLabel != nil && updated.speakerLabel == nil {
                    updated.speakerLabel = t.piece.speakerLabel
                    updated.speaker = t.piece.speaker
                    if moved { updated.rect = updated.rect.union(t.piece.rect) }   // vẫn phủ nhãn "(Sam)"
                }
                // 1.20: đã là lời thoại thì GIỮ là lời thoại (chữ vàng), kể cả khi lần quét này OCR tách mất "(Sam)"
                if t.piece.category == .dialogue && updated.category != .dialogue { updated.category = .dialogue }
                t.piece = updated
                if moved {
                    t.style = StyleSampler.sample(frame: frame, rect: piece.rect)
                    t.isPaper = skipPaperText && StyleSampler.isPaperText(frame: frame, rect: piece.rect, style: t.style)
                }
                t.thumb = StyleSampler.thumbnail(frame: frame, rect: t.piece.rect)
                if t.key != key {
                    let oldTokens = t.key.split(separator: " ").map(String.init)
                    t.key = key
                    if let m = dbMatch {
                        let dv = dataVI(t.piece.sourceText, m.vi)
                        if t.translation != dv { t.translation = dv; t.shownAt = now }
                        t.fromDatabase = true
                        t.dbIndex = m.index
                    } else if TranslationMemory.similarity(keyTokens, oldTokens) < 0.95 && !t.fromDatabase {
                        t.translation = nil
                        t.shownAt = nil
                        translate(t)
                    }
                } else if t.translation == nil && !t.aiPending {
                    translate(t)
                }
            } else {
                let t = TrackedPiece(id: "ss\(nextID)", order: nextID, key: key, piece: piece)
                nextID += 1
                t.style = StyleSampler.sample(frame: frame, rect: piece.rect)
                t.isPaper = skipPaperText && StyleSampler.isPaperText(frame: frame, rect: piece.rect, style: t.style)
                t.thumb = StyleSampler.thumbnail(frame: frame, rect: piece.rect)
                if t.isPaper {
                    // Không dịch chữ trên giấy -> không tốn lượt AI
                    tracked.append(t)
                    matchedIDs.insert(t.id)
                    continue
                }
                if let m = dbMatch {
                    t.translation = dataVI(piece.sourceText, m.vi)
                    t.fromDatabase = true
                    t.dbIndex = m.index
                    t.shownAt = now
                } else {
                    translate(t)
                }
                tracked.append(t)
                matchedIDs.insert(t.id)
            }
        }

        // Khung không còn thấy chữ gốc trong lần quét này
        for t in tracked where !matchedIDs.contains(t.id) {
            t.misses += 1
            if isSceneCut && t.piece.category != .dialogue {
                t.sceneCut = true
                if t.goneAt == nil { t.goneAt = now }
                continue
            }
            if t.goneAt == nil {
                let now2 = StyleSampler.thumbnail(frame: frame, rect: t.piece.rect)
                let vanished = StyleSampler.thumbDiff(now2, t.thumb) > 16
                if vanished || t.misses >= 2 { t.goneAt = now }
            }
        }
        tracked.removeAll { t in
            if matchedIDs.contains(t.id) { return false }
            guard let gone = t.goneAt else { return false }
            if t.translation == nil {
                // Đang chờ AI: giữ tối đa 3 giây để bản dịch về kịp hiện
                return !(t.aiPending && now.timeIntervalSince(gone) < 3.0)
            }
            if !t.isConfirmed { return true }
            return !t.isVisible(at: now)
        }
    }

    private func translate(_ t: TrackedPiece) {
        guard !t.isPaper else { return }
        let src = t.piece.sourceText
        if let m = memory.lookupMatch(src) {
            t.translation = dataVI(src, m.vi)
            t.fromDatabase = true
            t.dbIndex = m.index
            t.shownAt = Date()
            return
        }
        if let vi = GameVocabulary.uiDictionary[t.key] {
            t.translation = Self.isAllCaps(src) ? vi.uppercased(with: Locale(identifier: "vi_VN")) : vi
            t.fromDatabase = true
            t.shownAt = Date()
            return
        }
        // 1.24: lời thoại chỉ gọi tên "(Chris) Sam!" -> giữ nguyên, không cần dịch
        if PieceBuilder.isNamesOnly(src, filter: filter) {
            t.translation = src
            t.fromDatabase = true
            t.shownAt = Date()
            return
        }
        // Chữ IN HOA (lựa chọn câu trả lời, tiêu đề): gửi AI dạng câu thường, rồi in hoa lại bản dịch
        let allCaps = Self.isAllCaps(src)
        let styled: (String) -> String = { allCaps ? $0.uppercased(with: Locale(identifier: "vi_VN")) : $0 }
        let aiKey = "ai|" + t.key
        let preferApple = engineMode == .appleThenGoogle || engineMode == .appleOnly
        let aiSource = allCaps ? sentenceCase(src) : src
        // Tên riêng: tên có sẵn + từ viết hoa giữa câu không có trong từ điển tiếng Anh
        var protected: [String] = []
        let words = aiSource.split(separator: " ").map { GameTextFilter.stripPossessive(String($0).trimmingCharacters(in: .punctuationCharacters)) }
        for (i, w) in words.enumerated() where !w.isEmpty {
            if filter.isName(w) || (i > 0 && GameTextFilter.isProperNounCandidate(w) && !filter.isEnglishWord(w.lowercased())) {
                if !protected.contains(w) { protected.append(w) }
            }
        }
        // 1.24: bản dịch đã lưu trên máy cũng phải còn đủ tên ("Sam"), thiếu tên thì bỏ, dịch lại
        if preferApple, let vi = online.cached(aiKey), Self.keepsNames(protected, in: vi) {
            t.translation = styled(vi)
            t.shownAt = Date()
            return
        }
        if engineMode != .appleOnly, let vi = online.cached(t.key), Self.keepsNames(protected, in: vi) {
            t.translation = styled(vi)
            t.shownAt = Date()
            return
        }
        online.forget(aiKey)
        online.forget(t.key)
        guard useOnlineAI, engineMode != .offline, !t.aiPending else { return }

        let key = t.key
        t.aiPending = true
        t.requestKey = key
        weak var target = t
        let done = AIDeliveryFlag()

        // 1.14: giao bản dịch cho ĐÚNG khung đã gửi (kể cả khi OCR đọc chữ hơi khác ở lần quét sau)
        let deliver: (String) -> Void = { [weak self] raw in
            guard let self = self else { return }
            let vi = styled(raw)
            self.queue.async {
                guard !done.value else { return }
                done.value = true
                var changed = false
                for item in self.tracked where item.translation == nil
                    && (item === target || item.key == key || item.requestKey == key) {
                    item.translation = vi
                    item.aiPending = false
                    item.shownAt = Date()
                    changed = true
                }
                if changed {
                    let boxes = SubtitleLayoutEngine.layout(self.visibleItems(now: Date()), refW: self.frameRefW, stabilizer: self.stabilizer)
                    self.onAsyncUpdate?(boxes)
                }
            }
        }
        let google: () -> Void = { [weak self] in
            self?.online.request(text: aiSource, key: key, protectedWords: protected, completion: deliver)
        }

        if preferApple && OnDeviceAITranslator.shared.isAvailable {
            let context = AITranslationContext(
                gameTitle: gameTitle,
                category: t.piece.category,
                speaker: t.piece.speaker,
                protectedWords: protected + Array(memory.names.prefix(40)).map { $0.capitalized },
                previousLines: recentDialogue
            )
            if t.piece.category == .dialogue {
                recentDialogue.append(src)
                if recentDialogue.count > 3 { recentDialogue.removeFirst() }
            }
            let mode = engineMode
            let namesInSentence = protected
            OnDeviceAITranslator.shared.translate(aiSource, key: aiKey, context: context) { [weak self] vi in
                // 1.20: câu dịch AI phải còn ĐỦ tên riêng của câu gốc ("Sam", "Josh"...).
                // AI làm rơi tên -> dùng Google (tên được khoá bằng mã giữ chỗ nên không mất).
                if let vi = vi, mode == .appleThenGoogle, !Self.keepsNames(namesInSentence, in: vi) {
                    google()
                    return
                }
                if let vi = vi {
                    let fixed = Self.reinsertNames(namesInSentence, source: aiSource, vi: vi)
                    self?.online.store(key: aiKey, value: fixed)
                    deliver(fixed)
                } else if mode == .appleThenGoogle {
                    google()
                } else {
                    self?.queue.async { for item in self?.tracked ?? [] where item.requestKey == key { item.aiPending = false } }
                }
            }
            // Apple Intelligence chậm quá 1,2 giây -> gửi Google song song, bản nào về trước thì hiện
            if mode == .appleThenGoogle {
                queue.asyncAfter(deadline: .now() + 1.2) {
                    if !done.value { google() }
                }
            }
        } else if engineMode != .appleOnly {
            google()
        }
    }

    /// 1.24: câu Việt hoá trong data cũng phải giữ tên nhân vật có trong câu gốc
    private func dataVI(_ src: String, _ vi: String) -> String {
        var names: [String] = []
        for raw in src.split(separator: " ") {
            let w = GameTextFilter.stripPossessive(String(raw).trimmingCharacters(in: .punctuationCharacters))
            if !w.isEmpty, filter.isName(w), !names.contains(w) { names.append(w) }
        }
        return names.isEmpty ? vi : Self.reinsertNames(names, source: src, vi: vi)
    }

    /// 1.24: chèn lại tên riêng bị máy dịch làm rơi (đầu câu nếu tên ở nửa đầu câu gốc, cuối câu nếu ở nửa sau)
    static func reinsertNames(_ names: [String], source: String, vi: String) -> String {
        var out = vi.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in names where !keepsNames([word], in: out) {
            let pos = source.range(of: word).map { source.distance(from: source.startIndex, to: $0.lowerBound) } ?? 0
            if pos <= source.count / 2 {
                out = word + ", " + out.prefix(1).lowercased() + out.dropFirst()
            } else if let last = out.last, ".!?…".contains(last) {
                out = String(out.dropLast()) + ", " + word + String(last)
            } else {
                out += ", " + word
            }
        }
        return out
    }

    /// 1.20: bản dịch còn đủ tên riêng của câu gốc (không phân biệt hoa thường / dấu)
    static func keepsNames(_ names: [String], in vi: String) -> Bool {
        let hay = vi.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return names.allSatisfy { n in
            hay.contains(n.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count >= 3 && letters.allSatisfy { $0.isUppercase }
    }

    /// "IT MAKES ME HAPPY" -> "It makes me happy" (giữ tên riêng viết hoa)
    private func sentenceCase(_ text: String) -> String {
        let lower = text.lowercased()
        var words = lower.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (i, w) in words.enumerated() {
            let core = w.trimmingCharacters(in: .punctuationCharacters)
            if core == "i" || core.hasPrefix("i'") || filter.isName(GameTextFilter.stripPossessive(core)) || i == 0 {
                if let f = w.firstIndex(where: { $0.isLetter }) {
                    words[i] = w.replacingCharacters(in: f...f, with: String(w[f]).uppercased())
                }
            }
        }
        return words.joined(separator: " ")
    }
}

final class AIDeliveryFlag {
    var value = false
}
