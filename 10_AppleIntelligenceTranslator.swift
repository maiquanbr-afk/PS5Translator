// ============================================================================
// FILE 10: 10_AppleIntelligenceTranslator.swift
// PHIÊN BẢN: PS5Translator 1.12
//
// Dịch bằng Apple Intelligence CHẠY TRÊN IPHONE (Foundation Models, iOS 26+).
// - Không cần Internet, hiểu ngữ cảnh: tên game, thoại / menu / nhiệm vụ, người nói,
//   các câu thoại trước đó, danh sách tên riêng phải giữ nguyên.
// - Máy không hỗ trợ (chưa iOS 26, chưa bật Apple Intelligence, máy đời cũ, model chưa
//   tải xong, hoặc model từ chối câu) -> chỉ dịch bằng data Việt hoá (1.28: đã bỏ Google Dịch).
// ============================================================================

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TranslationEngineMode: String, CaseIterable, Identifiable {
    case appleThenGoogle
    case appleOnly
    case googleOnly
    case offline

    var id: String { rawValue }

    // 1.28: ĐÃ BỎ Google Dịch. Các lựa chọn cũ (Tất cả / Apple / Google) đều chạy "Data Việt hoá → AI iPhone"
    var title: String {
        switch self {
        case .appleThenGoogle, .appleOnly, .googleOnly: return "Data Việt hoá → AI iPhone"
        case .offline: return "Chỉ data Việt hoá"
        }
    }

    var detail: String {
        switch self {
        case .appleThenGoogle, .appleOnly, .googleOnly:
            return "Câu có trong data Việt hoá (khớp chữ hoặc khớp nghĩa) lấy data; câu không có thì Apple Intelligence trên iPhone dịch theo văn phong data. Không gửi chữ lên Internet."
        case .offline: return "Chỉ hiện câu có trong data Việt hoá và từ điển menu."
        }
    }
}

struct AITranslationContext {
    var gameTitle: String
    var category: TextRegionCategory
    var speaker: String?
    var protectedWords: [String]
    var previousLines: [String]
    /// 1.27: câu Việt hoá chính thức của game giống câu cần dịch (học xưng hô, văn phong, thuật ngữ)
    var examples: [(en: String, vi: String)] = []
    /// 1.28: câu Việt hoá CÓ THỂ cùng nghĩa (data dịch ngược nên chữ Anh khác bản gốc) -> cùng nghĩa thì dùng nguyên văn
    var sameMeaningCandidates: [(en: String, vi: String)] = []
}

final class OnDeviceAITranslator {
    static let shared = OnDeviceAITranslator()

    private let lock = NSLock()
    private var pending: Set<String> = []
    private var inFlight = 0
    private var waiting: [(text: String, key: String, context: AITranslationContext, completion: (String?) -> Void)] = []
    private let maxConcurrent = 2
    private let maxWaiting = 6

    /// Trạng thái hiển thị trong app
    var statusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return supportsVietnamese
                    ? "✅ Apple Intelligence sẵn sàng (dịch trên máy)"
                    : "⚠️ Apple Intelligence trên máy này chưa hỗ trợ tiếng Việt → chỉ dịch bằng data"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "❌ iPhone này không hỗ trợ Apple Intelligence → chỉ dịch bằng data"
                case .appleIntelligenceNotEnabled: return "⚠️ Chưa bật Apple Intelligence (Cài đặt > Apple Intelligence & Siri)"
                case .modelNotReady: return "⏳ Apple Intelligence đang tải model, thử lại sau ít phút"
                @unknown default: return "⚠️ Apple Intelligence chưa sẵn sàng"
                }
            @unknown default:
                return "⚠️ Apple Intelligence chưa sẵn sàng"
            }
        }
        return "❌ Cần iOS 26 trở lên để dùng Apple Intelligence → chỉ dịch bằng data"
        #else
        return "❌ Bản build chưa có Foundation Models (cần Xcode 26) → chỉ dịch bằng data"
        #endif
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return supportsVietnamese }
        }
        #endif
        return false
    }

    private var supportsVietnamese: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let langs = SystemLanguageModel.default.supportedLanguages
            return langs.contains { $0.languageCode?.identifier == "vi" }
        }
        #endif
        return false
    }

    /// completion: bản dịch, hoặc nil nếu không dịch được
    func translate(_ text: String, key: String, context: AITranslationContext, completion: @escaping (String?) -> Void) {
        lock.lock()
        if pending.contains(key) { lock.unlock(); return }
        pending.insert(key)
        if inFlight >= maxConcurrent {
            waiting.append((text, key, context, completion))
            // Ưu tiên câu mới nhất trên màn hình: bỏ câu cũ đang chờ quá lâu
            if waiting.count > maxWaiting {
                let dropped = waiting.removeFirst()
                pending.remove(dropped.key)
                lock.unlock()
                dropped.completion(nil)
                return
            }
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()
        run(text, key: key, context: context, completion: completion)
    }

    private func run(_ text: String, key: String, context: AITranslationContext, completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = Self.buildPrompt(text, context: context)
            Task.detached(priority: .userInitiated) { [weak self] in
                var result: String?
                do {
                    let session = LanguageModelSession(instructions: """
                    Bạn là dịch giả Việt hoá game chuyên nghiệp. Nhiệm vụ: dịch chữ tiếng Anh xuất hiện trong game sang tiếng Việt.
                    Quy tắc:
                    - Dịch sát nghĩa nhưng tự nhiên, đúng bối cảnh và giọng nhân vật. Lời thoại dùng văn nói.
                    - Xưng hô, văn phong và cách dịch thuật ngữ PHẢI theo các câu Việt hoá mẫu của game nếu được đưa kèm.
                    - Không dùng "bạn" trong lời thoại giữa các nhân vật; chọn xưng hô theo quan hệ (ta/con, ta/ngươi, tôi/bà, mày/tao...).
                    - Menu, nút, nhiệm vụ: dịch ngắn gọn như trong game Việt hoá.
                    - Giữ nguyên tên riêng có trong câu gốc, tên nút tay cầm (L1, R2, X, O...), con số.
                    - TUYỆT ĐỐI không thêm tên người hay chi tiết nào không có trong câu gốc. Không bỏ bớt ý.
                    - Không lặp lại tên người nói ở đầu câu dịch.
                    - Chỉ trả về đúng câu tiếng Việt, không giải thích, không thêm dấu ngoặc kép.
                    """)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                    result = Self.clean(response.content, original: text)
                } catch {
                    result = nil   // từ chối / lỗi
                }
                self?.finish(key: key)
                completion(result)
            }
            return
        }
        #endif
        finish(key: key)
        completion(nil)
    }

    private func finish(key: String) {
        lock.lock()
        pending.remove(key)
        inFlight = max(0, inFlight - 1)
        var next: (text: String, key: String, context: AITranslationContext, completion: (String?) -> Void)?
        if !waiting.isEmpty {
            next = waiting.removeLast()   // câu mới nhất trước
            inFlight += 1
        }
        lock.unlock()
        if let n = next {
            run(n.text, key: n.key, context: n.context, completion: n.completion)
        }
    }

    static func buildPrompt(_ text: String, context: AITranslationContext) -> String {
        var lines: [String] = []
        if !context.gameTitle.isEmpty { lines.append("Game: \(context.gameTitle)") }
        switch context.category {
        case .dialogue:
            lines.append("Loại chữ: lời thoại nhân vật" + (context.speaker.map { " (người nói: \($0))" } ?? ""))
        case .quest:
            lines.append("Loại chữ: nhiệm vụ / thông báo trên màn hình")
        case .menu:
            lines.append("Loại chữ: menu / hướng dẫn thao tác / vật phẩm")
        }
        if !context.previousLines.isEmpty {
            lines.append("Các câu thoại ngay trước đó (chỉ để hiểu ngữ cảnh, KHÔNG dịch):")
            for l in context.previousLines.suffix(3) { lines.append("- \(l)") }
        }
        if !context.sameMeaningCandidates.isEmpty {
            lines.append("Bản Việt hoá chính thức có thể đã có câu này (phần tiếng Anh của data là bản dịch ngược nên chữ có thể khác câu cần dịch).")
            lines.append("Nếu câu cần dịch CÙNG NGHĨA với một câu dưới đây, trả về NGUYÊN VĂN câu tiếng Việt của câu đó, không sửa chữ nào:")
            for e in context.sameMeaningCandidates.prefix(3) { lines.append("- \(e.en) => \(e.vi)") }
            lines.append("Nếu không câu nào cùng nghĩa thì tự dịch.")
        }
        if !context.examples.isEmpty {
            lines.append("Câu Việt hoá mẫu của game (theo đúng xưng hô, văn phong, thuật ngữ):")
            for e in context.examples.prefix(4) { lines.append("- \(e.en) => \(e.vi)") }
        }
        let names = Array(Set(context.protectedWords)).prefix(12)
        if !names.isEmpty { lines.append("Tên riêng trong câu (giữ nguyên): \(names.joined(separator: ", "))") }
        lines.append("Câu cần dịch: \(text)")
        lines.append("Bản dịch tiếng Việt:")
        return lines.joined(separator: "\n")
    }

    static func clean(_ raw: String, original: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Bản dịch tiếng Việt:", "Bản dịch:", "Dịch:", "Tiếng Việt:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // Chỉ lấy dòng đầu nếu model giải thích thêm
        if let firstLine = s.split(separator: "\n").first, original.split(separator: "\n").count <= 1 {
            s = String(firstLine)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` "))
        guard !s.isEmpty, s.lowercased() != original.lowercased() else { return nil }
        return s
    }
}
