// ============================================================================
// FILE 11: 11_TVInstaller.swift  (bản 1.18)
// NHIỆM VỤ: Cài app "PS5 Translator TV" lên TV Samsung TRỰC TIẾP từ iPhone, không cần máy tính.
// Làm đúng các bước mà bộ cài Node (deploy_ps5.mjs + sdb.exe) làm trên PC:
//   1. Nói chuyện với TV qua giao thức SDB (TCP cổng 26101, TV phải bật Developer Mode
//      và đặt "Host PC IP" = IP của iPhone).
//   2. Đăng nhập tài khoản Samsung (trang của Samsung trả token về http://localhost:4794).
//   3. Xin chứng chỉ author + distributor cho đúng DUID của TV (svdca.samsungqbe.com).
//   4. Ký gói .wgt (author-signature.xml + signature1.xml, RSA-SHA512) và nén ZIP.
//   5. Đẩy gói sang TV, chạy "vd_appinstall", rồi mở app.
// Mã nguồn app TV nằm trong app iPhone (thư mục TVApp/ -> tài nguyên của app).
// Khi cài, IP Wi-Fi của iPhone được ghi thẳng vào tv_main.js nên TV kết nối được ngay.
// ============================================================================

import SwiftUI
import Network
import Security
import CryptoKit
import Compression
import WebKit

// MARK: - Lỗi

struct TVInstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum TVAppInfo {
    static let packageId = "CTSubV0001"
    static let appId = "CTSubV0001.ConsoleTranslatorV"
    static let sdbPort: UInt16 = 26101
    static let sdkToolsDir = "/home/owner/share/tmp/sdk_tools"
}

// MARK: - Tiện ích nhị phân

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE16(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func readLE32(_ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[self.startIndex + offset + i]) << (8 * UInt32(i)) }
        return v
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

/// Đặt hạn giờ cho một thao tác mạng: quá giờ thì gọi `onTimeout` (thường là huỷ kết nối)
final class Deadline {
    private var work: DispatchWorkItem?
    private(set) var fired = false
    init(seconds: Double, onTimeout: @escaping () -> Void) {
        let w = DispatchWorkItem { [weak self] in self?.fired = true; onTimeout() }
        work = w
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: w)
    }
    func cancel() { work?.cancel() }
}

// MARK: - Kết nối TCP đơn giản (async/await) dùng cho SDB và HTTP nội bộ

final class TCPStream {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "ps5translator.tcp")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    /// Kết quả: "open" | "refused" | "silent"
    func open(timeout: Double) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var done = false
            let lock = NSLock()
            func finish(_ r: String) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                cont.resume(returning: r)
            }
            let dl = Deadline(seconds: timeout) { [weak self] in
                finish("silent")
                self?.connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: dl.cancel(); finish("open")
                case .waiting(let err), .failed(let err):
                    if case .posix(let code) = err, code == .ECONNREFUSED { dl.cancel(); finish("refused") }
                    else if case .failed = state { dl.cancel(); finish("silent") }
                case .cancelled: finish("silent")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: TVInstallError("Mất kết nối TV (\(error.localizedDescription))")) }
                else { cont.resume() }
            })
        }
    }

    private func receiveMore() async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    self?.buffer.append(data)
                    cont.resume(returning: true)
                } else if let error = error {
                    cont.resume(throwing: TVInstallError("Mất kết nối TV (\(error.localizedDescription))"))
                } else if isComplete {
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
    }

    func read(exactly n: Int) async throws -> Data {
        while buffer.count < n {
            if try await !receiveMore() { throw TVInstallError("TV đã đóng kết nối") }
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    /// Đọc đến khi bên kia đóng kết nối (dùng cho HTTP "Connection: close")
    func readToEnd(limit: Int = 512 * 1024) async throws -> Data {
        while buffer.count < limit {
            if try await !receiveMore() { break }
        }
        let out = buffer
        buffer.removeAll()
        return out
    }

    func close() { connection.cancel() }
}

// MARK: - Giao thức SDB (biến thể ADB của Samsung) — chỉ phần cần để cài app

final class SDBClient {
    private struct Packet { let command: String; let arg0: UInt32; let arg1: UInt32; let payload: Data }

    let host: String
    private var stream: TCPStream?
    private var nextLocalId: UInt32 = 1
    private var maxPayload = 4096

    init(host: String) { self.host = host }

    private static func code(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    private func send(_ command: String, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) async throws {
        guard let stream = stream else { throw TVInstallError("Chưa kết nối TV") }
        var header = Data()
        let cmd = SDBClient.code(command)
        header.appendLE(cmd)
        header.appendLE(arg0)
        header.appendLE(arg1)
        header.appendLE(UInt32(payload.count))
        header.appendLE(payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        header.appendLE(cmd ^ 0xFFFFFFFF)
        try await stream.write(header + payload)
    }

    private func receive() async throws -> Packet {
        guard let stream = stream else { throw TVInstallError("Chưa kết nối TV") }
        let h = try await stream.read(exactly: 24)
        let cmdBytes = h.prefix(4)
        let command = String(bytes: cmdBytes, encoding: .ascii) ?? "????"
        let length = Int(h.readLE32(12))
        guard length <= 1 << 20 else { throw TVInstallError("Gói SDB lỗi từ TV") }
        let payload = length > 0 ? try await stream.read(exactly: length) : Data()
        return Packet(command: command, arg0: h.readLE32(4), arg1: h.readLE32(8), payload: payload)
    }

    /// Chạy một thao tác, quá `seconds` giây thì huỷ kết nối (thao tác sẽ ném lỗi hết giờ)
    private func withTimeout<T>(_ seconds: Double, _ what: String, _ op: () async throws -> T) async throws -> T {
        let dl = Deadline(seconds: seconds) { [weak self] in self?.stream?.close() }
        defer { dl.cancel() }
        do { return try await op() } catch {
            if dl.fired { throw TVInstallError("TV không trả lời (\(what), quá \(Int(seconds)) giây)") }
            throw error
        }
    }

    /// Mở kết nối SDB. Ném lỗi kèm hướng dẫn nếu TV từ chối.
    func connect() async throws {
        let s = TCPStream(host: host, port: TVAppInfo.sdbPort)
        let state = await s.open(timeout: 6)
        switch state {
        case "open": break
        case "refused":
            throw TVInstallError("TV có trong mạng nhưng cổng 26101 đang đóng. Hãy bật Developer Mode trên TV (Apps → bấm 1-2-3-4-5), đặt Host PC IP = IP iPhone, rồi TẮT HẲN và bật lại TV.")
        default:
            throw TVInstallError("Không thấy TV ở \(host). Kiểm tra IP TV và iPhone cùng mạng Wi-Fi (không dùng Wi-Fi khách).")
        }
        stream = s
        do {
            try await withTimeout(8, "bắt tay SDB") {
                try await send("CNXN", 0x0100_0000, 256 * 1024, Data("host::sdb-net-client\0".utf8))
                while true {
                    let p = try await receive()
                    if p.command == "CNXN" {
                        let deviceMax = Int(p.arg1)
                        maxPayload = max(1024, min(deviceMax > 0 ? deviceMax : 4096, 32 * 1024))
                        return
                    }
                }
            }
        } catch {
            close()
            throw TVInstallError("TV không cho iPhone kết nối SDB. Trong Developer Mode của TV, \"Host PC IP\" phải đúng là IP iPhone (\(TVWebSocketServer.currentWiFiIP() ?? "?")), sau đó tắt hẳn TV và bật lại. (\(error.localizedDescription))")
        }
    }

    func close() {
        stream?.close()
        stream = nil
    }

    /// `sdb shell <lệnh>` — trả về toàn bộ chữ TV in ra
    func shell(_ command: String, timeout: Double = 30) async throws -> String {
        try await withTimeout(timeout, command.components(separatedBy: " ").prefix(2).joined(separator: " ")) {
            let local = nextLocalId; nextLocalId += 1
            try await send("OPEN", local, 0, Data("shell:\(command)\0".utf8))
            var remote: UInt32 = 0
            var output = Data()
            while true {
                let p = try await receive()
                guard p.arg1 == local else { continue }      // gói của luồng cũ
                switch p.command {
                case "OKAY":
                    remote = p.arg0
                case "WRTE":
                    output.append(p.payload)
                    try await send("OKAY", local, p.arg0)
                case "CLSE":
                    if remote != 0 { try? await send("CLSE", local, remote) }
                    return String(decoding: output, as: UTF8.self)
                default:
                    break
                }
            }
        }
    }

    /// `sdb push` — gửi một file sang TV bằng dịch vụ sync
    func push(_ data: Data, to remotePath: String, timeout: Double = 90) async throws {
        try await withTimeout(timeout, "gửi file") {
            let local = nextLocalId; nextLocalId += 1
            try await send("OPEN", local, 0, Data("sync:\0".utf8))
            var remote: UInt32 = 0
            var reply = Data()

            // Chờ OKAY mở luồng
            while remote == 0 {
                let p = try await receive()
                guard p.arg1 == local else { continue }
                if p.command == "OKAY" { remote = p.arg0 }
                else if p.command == "CLSE" { throw TVInstallError("TV từ chối nhận file (sync)") }
            }

            // Dựng luồng sync: SEND "<đường dẫn>,33279" | DATA x n (4000 byte) | DONE <mtime>
            var sync = Data()
            let pathMode = Data("\(remotePath),33279".utf8)        // 33279 = 0100777
            sync.append(Data("SEND".utf8)); sync.appendLE(UInt32(pathMode.count)); sync.append(pathMode)
            var offset = 0
            while offset < data.count {
                let n = min(4000, data.count - offset)
                sync.append(Data("DATA".utf8)); sync.appendLE(UInt32(n))
                sync.append(data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + n))
                offset += n
            }
            sync.append(Data("DONE".utf8)); sync.appendLE(UInt32(Date().timeIntervalSince1970))

            // Gửi từng gói WRTE, mỗi gói chờ TV trả OKAY (luật điều tiết của ADB/SDB)
            var sent = 0
            while sent < sync.count {
                let n = min(maxPayload, sync.count - sent)
                try await send("WRTE", local, remote, sync.subdata(in: sent ..< sent + n))
                sent += n
                var acked = false
                while !acked {
                    let p = try await receive()
                    guard p.arg1 == local else { continue }
                    switch p.command {
                    case "OKAY": acked = true
                    case "WRTE": reply.append(p.payload); try await send("OKAY", local, remote)
                    case "CLSE": throw TVInstallError("TV ngắt khi đang nhận file: \(String(decoding: reply, as: UTF8.self))")
                    default: break
                    }
                }
            }

            // Chờ kết quả: "OKAY" hoặc "FAIL<len><lý do>"
            while reply.count < 8 {
                let p = try await receive()
                guard p.arg1 == local else { continue }
                if p.command == "WRTE" { reply.append(p.payload); try await send("OKAY", local, remote) }
                else if p.command == "CLSE" { break }
            }
            let head = String(decoding: reply.prefix(4), as: UTF8.self)
            try? await send("WRTE", local, remote, { var q = Data("QUIT".utf8); q.appendLE(0); return q }())
            try? await send("CLSE", local, remote)
            if head != "OKAY" {
                let reason = reply.count > 8 ? String(decoding: reply.dropFirst(8), as: UTF8.self) : head
                throw TVInstallError("TV không ghi được file: \(reason)")
            }
        }
    }
}

// MARK: - DER tối thiểu (đủ cho CSR PKCS#10)

enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ parts: [UInt8]...) -> [UInt8] {
        let body = parts.flatMap { $0 }
        return [tag] + length(body.count) + body
    }
    static func tlvList(_ tag: UInt8, _ parts: [[UInt8]]) -> [UInt8] {
        let body = parts.flatMap { $0 }
        return [tag] + length(body.count) + body
    }
    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlvList(0x30, parts) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tlvList(0x31, parts) }
    static func oid(_ text: String) -> [UInt8] {
        let n = text.split(separator: ".").compactMap { Int($0) }
        var out: [UInt8] = [UInt8(n[0] * 40 + n[1])]
        for value in n.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            var v = value >> 7
            while v > 0 { chunk.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }
}

// MARK: - Chứng chỉ Samsung

struct SamsungAuth: Codable { let accessToken: String; let userId: String; let email: String }

struct TizenSigningIdentity: Codable {
    var privateKeyDER: Data          // PKCS#1 RSAPrivateKey
    var author: Data                 // DER
    var distributor: Data            // DER
    var profile: Data?               // device-profile.xml
    var duids: [String]
    var email: String
    var createdAt: Date

    func privateKey() throws -> SecKey {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                    kSecAttrKeySizeInBits as String: 2048]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKeyDER as CFData, attrs as CFDictionary, &err) else {
            throw TVInstallError("Không đọc được khoá ký đã lưu")
        }
        return key
    }

    // Lưu trong Keychain: dùng lại cùng khoá -> lần sau cập nhật app TV không bị lỗi "author mismatch"
    private static let account = "tizen-signing-identity"
    private static let service = "com.ps5viet.translator.tv"

    static func load() -> TizenSigningIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TizenSigningIdentity.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: TizenSigningIdentity.service,
                                kSecAttrAccount as String: TizenSigningIdentity.account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

enum SamsungCertificateService {
    static let authorURL = URL(string: "https://svdca.samsungqbe.com/apis/v3/authors")!
    static let distributorV1URL = URL(string: "https://svdca.samsungqbe.com/apis/v1/distributors")!
    static let distributorV3URL = URL(string: "https://svdca.samsungqbe.com/apis/v3/distributors")!

    static func newKey() throws -> SecKey {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeySizeInBits as String: 2048]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw TVInstallError("Không tạo được khoá RSA")
        }
        return key
    }

    private static func name(_ pairs: [(String, String)]) -> [UInt8] {
        let oids = ["C": "2.5.4.6", "ST": "2.5.4.8", "L": "2.5.4.7", "O": "2.5.4.10", "OU": "2.5.4.11",
                    "CN": "2.5.4.3", "email": "1.2.840.113549.1.9.1"]
        let tags: [String: UInt8] = ["C": 0x13, "email": 0x16]
        let rdns = pairs.map { pair -> [UInt8] in
            let (key, value) = pair
            let bytes = key == "email" ? Array(value.data(using: .isoLatin1) ?? Data(value.utf8)) : Array(value.utf8)
            return DER.set(DER.seq(DER.oid(oids[key]!), DER.tlv(tags[key] ?? 0x0C, bytes)))
        }
        return DER.tlvList(0x30, rdns)
    }

    private static func request(subject: [UInt8], attributes: [UInt8], key: SecKey) throws -> String {
        guard let pub = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw TVInstallError("Không đọc được khoá công khai")
        }
        let spki = DER.seq(DER.seq(DER.oid("1.2.840.113549.1.1.1"), DER.tlv(0x05)), DER.tlv(0x03, [0], Array(pkcs1)))
        let info = DER.seq(DER.tlv(0x02, [0]), subject, spki, DER.tlv(0xA0, attributes))
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(info) as CFData, &err) as Data? else {
            throw TVInstallError("Không ký được yêu cầu chứng chỉ")
        }
        let der = DER.seq(info, DER.seq(DER.oid("1.2.840.113549.1.1.11"), DER.tlv(0x05)), DER.tlv(0x03, [0], Array(sig)))
        let b64 = Data(der).base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j])); i = j
        }
        return "-----BEGIN CERTIFICATE REQUEST-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE REQUEST-----\n"
    }

    static func authorCSR(key: SecKey) throws -> String {
        try request(subject: name([("C", ""), ("ST", ""), ("L", ""), ("O", ""), ("OU", ""), ("CN", "ConsoleTranslator")]),
                    attributes: [], key: key)
    }

    static func distributorCSR(key: SecKey, duids: [String], email: String) throws -> String {
        let uris = ["URN:tizen:packageid="] + duids.map { "URN:tizen:deviceid=\($0)" }
        let generalNames = DER.tlvList(0x30, uris.map { DER.tlv(0x86, Array($0.utf8)) })
        let extensions = DER.seq(DER.seq(DER.oid("2.5.29.17"), DER.tlv(0x04, generalNames)))
        let attribute = DER.seq(DER.oid("1.2.840.113549.1.9.14"), DER.set(extensions))
        return try request(subject: name([("CN", "TizenSDK"), ("OU", ""), ("O", ""), ("L", ""), ("ST", ""), ("C", ""), ("email", email)]),
                           attributes: attribute, key: key)
    }

    static func certificateDER(_ bytes: Data) throws -> Data {
        let text = String(decoding: bytes, as: UTF8.self)
        var der = bytes
        if let r1 = text.range(of: "-----BEGIN CERTIFICATE-----"),
           let r2 = text.range(of: "-----END CERTIFICATE-----", range: r1.upperBound..<text.endIndex) {
            let b64 = text[r1.upperBound..<r2.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            der = Data(base64Encoded: b64) ?? Data()
        }
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw TVInstallError("Samsung trả về chứng chỉ không hợp lệ")
        }
        return der
    }

    private static func post(_ url: URL, fields: [String: String], csr: String, fileName: String) async throws -> Data {
        let boundary = "----PS5Translator\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"csr\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(Data(csr.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw TVInstallError("Không kết nối được máy chủ chứng chỉ Samsung: \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw TVInstallError("Phiên đăng nhập Samsung hết hạn. Hãy đăng nhập lại.") }
        guard (200..<300).contains(status), !data.isEmpty, data.count < 65536 else {
            throw TVInstallError("Samsung từ chối cấp chứng chỉ (mã \(status)). \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        return data
    }

    static func requestIdentity(auth: SamsungAuth, duids: [String]) async throws -> TizenSigningIdentity {
        guard !auth.email.isEmpty else { throw TVInstallError("Tài khoản Samsung chưa có email; Samsung không cấp chứng chỉ.") }
        let key = try newKey()
        let common = ["access_token": auth.accessToken, "user_id": auth.userId, "platform": "VD"]
        let authorRequest = try authorCSR(key: key)
        let authorReply = try await post(authorURL, fields: common, csr: authorRequest, fileName: "author.csr")
        let author = try certificateDER(authorReply)
        let csr = try distributorCSR(key: key, duids: duids, email: auth.email)
        var distFields = common
        distFields["privilege_level"] = "public"
        distFields["developer_type"] = "Individual"
        // v1 trả về device-profile.xml (quyền cài trên các TV này), v3 trả về chứng chỉ distributor
        let first = try await post(distributorV1URL, fields: distFields, csr: csr, fileName: "distributor.csr")
        let distReply = try await post(distributorV3URL, fields: distFields, csr: csr, fileName: "distributor.csr")
        let distributor = try certificateDER(distReply)
        var profile: Data?
        let text = String(decoding: first, as: UTF8.self)
        if let s = text.range(of: "<Profile"), let e = text.range(of: "</Profile>", options: .backwards), s.lowerBound < e.lowerBound {
            profile = Data(text[s.lowerBound..<e.upperBound].utf8)
        }
        guard let keyDER = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw TVInstallError("Không lưu được khoá ký")
        }
        return TizenSigningIdentity(privateKeyDER: keyDER, author: author, distributor: distributor, profile: profile,
                                    duids: duids, email: auth.email, createdAt: Date())
    }
}

// MARK: - Ký gói .wgt (giống hệt sign.mjs: W3C widget signature, RSA-SHA512)

enum WidgetSigner {
    static let dsig = "http://www.w3.org/2000/09/xmldsig#"

    static func wrap(_ b64: String) -> String {
        var out = ""
        var count = 0
        for ch in b64 {
            if count == 76 { out.append("\n"); count = 0 }
            out.append(ch); count += 1
        }
        return out
    }
    static func digest(_ data: Data) -> String { wrap(Data(SHA512.hash(data: data)).base64EncodedString()) }

    /// Như encodeURIComponent của JavaScript
    static func uri(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private static func roles(_ kind: String) -> (id: String, role: String, file: String) {
        kind == "author" ? ("AuthorSignature", "author", "author-signature.xml") : ("DistributorSignature", "distributor", "signature1.xml")
    }

    static func propObject(id: String, role: String, canonical: Bool) -> String {
        let ns = canonical ? " xmlns=\"\(dsig)\"" : ""
        return "<Object\(ns) Id=\"prop\"><SignatureProperties xmlns:dsp=\"http://www.w3.org/2009/xmldsig-properties\">" +
            "<SignatureProperty Id=\"profile\" Target=\"#\(id)\"><dsp:Profile URI=\"http://www.w3.org/ns/widgets-digsig#profile\"></dsp:Profile></SignatureProperty>" +
            "<SignatureProperty Id=\"role\" Target=\"#\(id)\"><dsp:Role URI=\"http://www.w3.org/ns/widgets-digsig#role-\(role)\"></dsp:Role></SignatureProperty>" +
            "<SignatureProperty Id=\"identifier\" Target=\"#\(id)\"><dsp:Identifier></dsp:Identifier></SignatureProperty>" +
            "</SignatureProperties></Object>"
    }

    static func sortedNames(_ files: [String: Data]) -> [String] {
        files.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
    }

    static func signedInfo(_ files: [String: Data], kind: String, canonical: Bool) -> String {
        let r = roles(kind)
        var xml = "<SignedInfo\(canonical ? " xmlns=\"\(dsig)\"" : "")>\n" +
            "<CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"></CanonicalizationMethod>\n" +
            "<SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha512\"></SignatureMethod>\n"
        for name in sortedNames(files) {
            xml += "<Reference URI=\"\(uri(name))\">\n" +
                "<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n" +
                "<DigestValue>\(digest(files[name]!))</DigestValue>\n</Reference>\n"
        }
        xml += "<Reference URI=\"#prop\">\n<Transforms>\n" +
            "<Transform Algorithm=\"http://www.w3.org/2006/12/xml-c14n11\"></Transform>\n</Transforms>\n" +
            "<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n" +
            "<DigestValue>\(digest(Data(propObject(id: r.id, role: r.role, canonical: true).utf8)))</DigestValue>\n</Reference>\n</SignedInfo>"
        return xml
    }

    static func signatureXml(_ files: [String: Data], kind: String, key: SecKey, chain: [Data]) throws -> String {
        let r = roles(kind)
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA512,
                                              Data(signedInfo(files, kind: kind, canonical: true).utf8) as CFData, &err) as Data? else {
            throw TVInstallError("Không ký được gói app TV")
        }
        let certs = chain.map { "<X509Certificate>\n\(wrap($0.base64EncodedString()))\n</X509Certificate>\n" }.joined()
        return "<Signature xmlns=\"\(dsig)\" Id=\"\(r.id)\">\n\(signedInfo(files, kind: kind, canonical: false))\n" +
            "<SignatureValue>\n\(wrap(sig.base64EncodedString()))\n</SignatureValue>\n<KeyInfo>\n<X509Data>\n\(certs)</X509Data>\n</KeyInfo>\n" +
            "\(propObject(id: r.id, role: r.role, canonical: false))\n</Signature>"
    }

    /// Trả về danh sách file theo thứ tự ghi ZIP (file gốc, author-signature.xml, signature1.xml)
    static func signPackage(_ files: [(String, Data)], key: SecKey, authorChain: [Data], distributorChain: [Data]) throws -> [(String, Data)] {
        let content = files.filter { $0.0 != "author-signature.xml" && !$0.0.hasPrefix("signature") }
        var map: [String: Data] = [:]
        for (n, d) in content { map[n] = d }
        let authorXml = Data(try signatureXml(map, kind: "author", key: key, chain: authorChain).utf8)
        map["author-signature.xml"] = authorXml
        let distXml = Data(try signatureXml(map, kind: "distributor", key: key, chain: distributorChain).utf8)
        return content + [("author-signature.xml", authorXml), ("signature1.xml", distXml)]
    }
}

// MARK: - Nén ZIP (deflate, như wgt.mjs)

enum ZipWriter {
    private static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return nil }
        let capacity = data.count + 4096
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 && n < data.count ? out.prefix(n) : nil
    }

    static func zip(_ files: [(String, Data)]) -> Data {
        var locals = Data(), central = Data()
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let packed = deflate(data)
            let method: UInt16 = packed == nil ? 0 : 8
            let body = packed ?? data
            let offset = UInt32(locals.count)

            locals.appendLE(0x04034b50); locals.appendLE16(20); locals.appendLE16(0x0800); locals.appendLE16(method)
            locals.appendLE(0x00210000); locals.appendLE(crc); locals.appendLE(UInt32(body.count)); locals.appendLE(UInt32(data.count))
            locals.appendLE16(UInt16(nameBytes.count)); locals.appendLE16(0)
            locals.append(nameBytes); locals.append(body)

            central.appendLE(0x02014b50); central.appendLE16(20); central.appendLE16(20); central.appendLE16(0x0800); central.appendLE16(method)
            central.appendLE(0x00210000); central.appendLE(crc); central.appendLE(UInt32(body.count)); central.appendLE(UInt32(data.count))
            central.appendLE16(UInt16(nameBytes.count)); central.appendLE16(0); central.appendLE16(0); central.appendLE16(0); central.appendLE16(0)
            central.appendLE(0); central.appendLE(offset)
            central.append(nameBytes)
        }
        var end = Data()
        end.appendLE(0x06054b50); end.appendLE16(0); end.appendLE16(0)
        end.appendLE16(UInt16(files.count)); end.appendLE16(UInt16(files.count))
        end.appendLE(UInt32(central.count)); end.appendLE(UInt32(locals.count)); end.appendLE16(0)
        return locals + central + end
    }
}

// MARK: - Mã nguồn app TV đóng gói trong app iPhone

enum TVAppSource {
    private static func resource(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext), let d = try? Data(contentsOf: url) else {
            throw TVInstallError("Thiếu file \(name).\(ext) của app TV trong app iPhone")
        }
        return d
    }

    static func pemToDER(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("-----BEGIN") else { return data }
        let b64 = text.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: b64) ?? data
    }

    static var authorCA: Data { get throws { pemToDER(try resource("tv_ca_author", "cer")) } }
    static var distributorCA: Data { get throws { pemToDER(try resource("tv_ca_public2", "crt")) } }

    /// 4 file của app TV, tv_main.js đã ghi sẵn IP iPhone
    static func files(iphoneIP: String) throws -> [(String, Data)] {
        var js = String(decoding: try resource("tv_main", "js"), as: UTF8.self)
        let lines = js.components(separatedBy: "\n").map { line -> String in
            guard line.contains("@@IPHONE_IP@@") else { return line }
            let indent = String(line.prefix { $0 == " " })
            return "\(indent)var BUILD_IP = \"\(iphoneIP)\"; // @@IPHONE_IP@@"
        }
        js = lines.joined(separator: "\n")
        return [
            ("config.xml", try resource("tv_app_config", "xml")),
            ("index.html", try resource("tv_app_index", "html")),
            ("tv_main.js", Data(js.utf8)),
            ("icon.png", try resource("tv_app_icon", "png")),
        ]
    }
}

// MARK: - Đăng nhập Samsung: máy chủ nhỏ trên iPhone nhận token ở http://localhost:4794

final class SamsungLoginServer {
    static let port: UInt16 = 4794
    static let state = "accountcheckdogeneratedstatetext"
    static var signInURL: URL {
        let redirect = "http://localhost:\(port)/signin/callback".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://account.samsung.com/accounts/be1dce529476c1a6d407c4c7578c31bd/signInGate?locale=&clientId=v285zxnl3h&redirect_uri=\(redirect)&state=\(state)&tokenType=TOKEN")!
    }

    private var listener: NWListener?
    private let onResult: (Result<SamsungAuth, Error>) -> Void
    private var finished = false

    init(onResult: @escaping (Result<SamsungAuth, Error>) -> Void) { self.onResult = onResult }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true          // chỉ nhận kết nối từ chính iPhone (localhost IPv4/IPv6)
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: SamsungLoginServer.port)!)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .main)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    static func parseForm(_ body: String) throws -> SamsungAuth {
        var form: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let dec: (String) -> String = { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0 }
            form[dec(kv[0])] = kv.count > 1 ? dec(kv[1]) : ""
        }
        guard form["state"] == state, let code = form["code"], let json = code.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty,
              let userId = obj["userId"] as? String, !userId.isEmpty else {
            throw TVInstallError("Đăng nhập Samsung không thành công")
        }
        return SamsungAuth(accessToken: token, userId: userId, email: obj["inputEmailID"] as? String ?? "")
    }

    func deliver(_ result: Result<SamsungAuth, Error>) {
        guard !finished else { return }
        finished = true
        onResult(result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func respond(_ ok: Bool) {
            let html = ok
                ? "<meta charset=\"utf-8\"><body style=\"font-family:-apple-system;background:#111;color:#f6d58e;text-align:center;padding-top:30vh\"><h2>Đăng nhập xong</h2><p>Quay lại app để cài lên TV.</p>"
                : "<meta charset=\"utf-8\"><body style=\"font-family:-apple-system;text-align:center;padding-top:30vh\"><h2>Đăng nhập không thành công</h2>"
            let body = Data(html.utf8)
            let head = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    let isPost = headers.hasPrefix("POST") && headers.contains("/signin/callback")
                    let lengthLine = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    let length = Int(lengthLine?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                    let bodyData = buffer[range.upperBound...]
                    if !isPost { respond(false); return }
                    if bodyData.count >= length || isComplete || error != nil {
                        do {
                            let auth = try SamsungLoginServer.parseForm(String(decoding: bodyData, as: UTF8.self))
                            respond(true); self.deliver(.success(auth))
                        } catch {
                            respond(false); self.deliver(.failure(error))
                        }
                        return
                    }
                }
                if isComplete || error != nil || buffer.count > 128 * 1024 { conn.cancel(); return }
                readMore()
            }
        }
        readMore()
    }
}

struct SamsungLoginWebView: UIViewRepresentable {
    let server: SamsungLoginServer

    func makeCoordinator() -> Coordinator { Coordinator(server: server) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: SamsungLoginServer.signInURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let server: SamsungLoginServer
        init(server: SamsungLoginServer) { self.server = server }

        // Dự phòng: nếu WebKit đưa luôn nội dung form thì đọc token ngay, không cần máy chủ nhỏ
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if url?.host == "localhost", url?.port == Int(SamsungLoginServer.port),
               let body = navigationAction.request.httpBody,
               let auth = try? SamsungLoginServer.parseForm(String(decoding: body, as: UTF8.self)) {
                server.deliver(.success(auth))
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Tìm TV Samsung trong mạng (cổng 8001 /api/v2/)

struct FoundTV: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    let name: String
    let model: String
    let developerMode: String?   // "1" = đang bật
    let developerIP: String?
}

enum TVDiscovery {
    static func httpGet(ip: String, port: UInt16, path: String, timeout: Double) async -> String? {
        let s = TCPStream(host: ip, port: port)
        guard await s.open(timeout: timeout) == "open" else { s.close(); return nil }
        let dl = Deadline(seconds: timeout + 1.5) { s.close() }
        defer { dl.cancel(); s.close() }
        do {
            try await s.write(Data("GET \(path) HTTP/1.1\r\nHost: \(ip):\(port)\r\nConnection: close\r\n\r\n".utf8))
            let data = try await s.readToEnd(limit: 64 * 1024)
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }

    static func info(ip: String) async -> FoundTV? {
        guard let text = await httpGet(ip: ip, port: 8001, path: "/api/v2/", timeout: 1.2),
              let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return nil }
        let device = obj["device"] as? [String: Any] ?? [:]
        let name = (device["name"] as? String) ?? (obj["name"] as? String) ?? "Samsung TV"
        let model = (device["modelName"] as? String) ?? (obj["type"] as? String) ?? ""
        let devMode = device["developerMode"].map { "\($0)" }
        let devIP = device["developerIP"] as? String
        return FoundTV(ip: ip, name: name, model: model, developerMode: devMode, developerIP: devIP)
    }

    static func scan(around iphoneIP: String) async -> [FoundTV] {
        let parts = iphoneIP.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".")
        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != iphoneIP }
        var found: [FoundTV] = []
        for chunk in stride(from: 0, to: hosts.count, by: 48).map({ Array(hosts[$0..<min($0 + 48, hosts.count)]) }) {
            await withTaskGroup(of: FoundTV?.self) { group in
                for ip in chunk { group.addTask { await TVDiscovery.info(ip: ip) } }
                for await tv in group { if let tv = tv { found.append(tv) } }
            }
        }
        return found.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }
}

// MARK: - Bộ điều phối cài đặt

@MainActor
final class TVInstallerModel: ObservableObject {
    @Published var tvIP: String = TVIPInput.normalize(UserDefaults.standard.string(forKey: "tv_installer_ip") ?? "")
    @Published var foundTVs: [FoundTV] = []
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var log: [String] = []
    @Published var showLogin = false
    @Published var done = false
    @Published var loginServer: SamsungLoginServer?

    private var loginContinuation: CheckedContinuation<SamsungAuth, Error>?

    var iphoneIP: String { TVWebSocketServer.currentWiFiIP() ?? "" }
    var hasSavedIdentity: Bool { TizenSigningIdentity.load() != nil }

    private func say(_ s: String) { log.append(s) }

    func scan() {
        guard !isScanning else { return }
        let ip = iphoneIP
        guard !ip.isEmpty else { say("✗ iPhone chưa kết nối Wi-Fi."); return }
        isScanning = true
        Task {
            let list = await TVDiscovery.scan(around: ip)
            self.foundTVs = list
            self.isScanning = false
            if list.isEmpty { self.say("Không tìm thấy TV Samsung trong mạng. Nhập IP TV bằng tay (TV: Cài đặt → Chung → Mạng → Trạng thái mạng).") }
            else if list.count == 1, self.tvIP.isEmpty { self.tvIP = list[0].ip }
        }
    }

    func forgetSamsungAccount() {
        TizenSigningIdentity.forget()
        say("Đã xoá chứng chỉ Samsung đã lưu. Lần cài sau sẽ đăng nhập lại.")
        objectWillChange.send()
    }

    private func signIn() async throws -> SamsungAuth {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SamsungAuth, Error>) in
            self.loginContinuation = cont
            let server = SamsungLoginServer { [weak self] result in
                Task { @MainActor in self?.finishLogin(result) }
            }
            do {
                try server.start()
                self.loginServer = server
                self.showLogin = true
            } catch {
                self.loginContinuation = nil
                cont.resume(throwing: TVInstallError("Không mở được cổng đăng nhập 4794: \(error.localizedDescription)"))
            }
        }
    }

    private func finishLogin(_ result: Result<SamsungAuth, Error>) {
        showLogin = false
        loginServer?.stop()
        loginServer = nil
        if let c = loginContinuation { loginContinuation = nil; c.resume(with: result) }
    }

    /// Người dùng đóng trang đăng nhập
    func loginDismissed() {
        if loginContinuation != nil { finishLogin(.failure(TVInstallError("Đã huỷ đăng nhập Samsung"))) }
    }

    func install() {
        guard !isWorking else { return }
        let tv = TVIPInput.normalize(tvIP)
        if tv != tvIP { tvIP = tv }
        let phone = iphoneIP
        guard tv.split(separator: ".").count == 4 else { say("✗ Nhập IP của TV trước."); return }
        guard !phone.isEmpty else { say("✗ iPhone chưa kết nối Wi-Fi."); return }
        UserDefaults.standard.set(tv, forKey: "tv_installer_ip")
        isWorking = true
        done = false
        log = []
        Task {
            do {
                try await self.runInstall(tv: tv, phone: phone)
                self.done = true
            } catch {
                self.say("✗ \(error.localizedDescription)")
            }
            self.isWorking = false
        }
    }

    private func runInstall(tv: String, phone: String) async throws {
        say("1. Kết nối TV \(tv):26101 ...")
        if let info = await TVDiscovery.info(ip: tv) {
            say("   TV: \(info.name) \(info.model)")
            if info.developerMode == "0" {
                throw TVInstallError("TV chưa bật Developer Mode. Trên TV: Apps → bấm 1-2-3-4-5 → Developer Mode ON → Host PC IP = \(phone) → tắt hẳn TV rồi bật lại.")
            }
            if let dev = info.developerIP, !dev.isEmpty, dev != phone, dev != "0.0.0.0" {
                throw TVInstallError("Host PC IP trên TV đang là \(dev), không phải IP iPhone (\(phone)). Sửa lại trong Developer Mode (Apps → 1-2-3-4-5) rồi tắt hẳn TV và bật lại.")
            }
        }
        let sdb = SDBClient(host: tv)
        try await sdb.connect()
        defer { sdb.close() }

        let duidOut = try await sdb.shell("0 getduid", timeout: 20)
        let duid = duidOut.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespacesAndNewlines).last ?? ""
        guard duid.range(of: "^[A-Za-z0-9]{8,40}$", options: .regularExpression) != nil else {
            throw TVInstallError("Không đọc được mã DUID của TV (\(duidOut.prefix(80)))")
        }
        say("   Đã kết nối. DUID: \(duid)")

        say("2. Chứng chỉ Samsung cho TV này ...")
        var identity: TizenSigningIdentity
        if let saved = TizenSigningIdentity.load(), saved.duids.contains(duid) {
            identity = saved
            say("   Dùng lại chứng chỉ đã lưu (\(saved.email)).")
        } else {
            say("   Mở trang đăng nhập tài khoản Samsung ...")
            let auth = try await signIn()
            say("   Đã đăng nhập: \(auth.email). Đang xin chứng chỉ ...")
            identity = try await SamsungCertificateService.requestIdentity(auth: auth, duids: [duid])
            identity.save()
            say("   Samsung đã cấp chứng chỉ.")
        }

        say("3. Đóng gói và ký app TV (IP iPhone \(phone) được ghi sẵn vào app) ...")
        let key = try identity.privateKey()
        let sourceFiles = try TVAppSource.files(iphoneIP: phone)
        let authorCA = try TVAppSource.authorCA
        let distributorCA = try TVAppSource.distributorCA
        let signed = try WidgetSigner.signPackage(sourceFiles, key: key,
                                                  authorChain: [identity.author, authorCA],
                                                  distributorChain: [identity.distributor, distributorCA])
        let wgt = ZipWriter.zip(signed)
        say("   Gói .wgt: \(wgt.count / 1024) KB")

        if let profile = identity.profile {
            do {
                try await sdb.push(profile, to: "\(TVAppInfo.sdkToolsDir)/device-profile.xml", timeout: 30)
                say("   Đã gửi quyền cài (device-profile) sang TV.")
            } catch {
                say("   (Bỏ qua device-profile: \(error.localizedDescription))")
            }
        }

        say("4. Cài lên TV ...")
        var uninstalledOld = false
        var attempt = 1
        while true {
            let remote = "\(TVAppInfo.sdkToolsDir)/tmp/ct-\(Int(Date().timeIntervalSince1970)).wgt"
            try await sdb.push(wgt, to: remote, timeout: 120)
            let reply = try await sdb.shell("0 vd_appinstall \(TVAppInfo.packageId) \(remote)", timeout: 150)
            _ = try? await sdb.shell("0 rm -f \(remote)", timeout: 10)
            if reply.contains("install completed") { break }

            let detail = reply.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(220)
            let lower = reply.lowercased()
            if !uninstalledOld && lower.contains("author") && (lower.contains("mismatch") || lower.contains("not match") || lower.contains("different")) {
                say("   App TV cũ được ký bằng chứng chỉ khác (cài từ máy tính). Gỡ bản cũ rồi cài lại ...")
                _ = try? await sdb.shell("0 vd_appuninstall \(TVAppInfo.appId)", timeout: 60)
                uninstalledOld = true
                continue
            }
            let isCert = lower.contains("certificate") || reply.range(of: "118(, ?-|0)12", options: .regularExpression) != nil
            let notYetValid = lower.contains("not yet valid") || lower.contains("not valid") || lower.contains("future")
                || !lower.contains("reason")
            if isCert && notYetValid && attempt < 4 {
                say("   TV báo chứng chỉ chưa có hiệu lực (đồng hồ TV chậm). Chờ 75 giây rồi thử lại (\(attempt)/3) ...")
                try await Task.sleep(nanoseconds: 75_000_000_000)
                attempt += 1
                continue
            }
            if isCert {
                throw TVInstallError("TV từ chối chứng chỉ: \(detail). Thử \"Đăng nhập lại Samsung\" rồi cài lại.")
            }
            throw TVInstallError("Cài không thành công: \(detail)")
        }
        say("   Cài xong!")

        say("5. Mở app trên TV ...")
        _ = try? await sdb.shell("0 was_execute \(TVAppInfo.appId)", timeout: 20)
        say("✓ HOÀN TẤT. App TV sẽ tự kết nối tới iPhone \(phone):\(AppConfig.webSocketPort).")
    }
}

// MARK: - Giao diện

struct TVInstallerView: View {
    @StateObject private var model = TVInstallerModel()
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepsCard
                    tvCard
                    actionCard
                    if !model.log.isEmpty { logCard }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Cài app lên TV Samsung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $model.showLogin, onDismiss: { model.loginDismissed() }) {
                NavigationView {
                    Group {
                        if let server = model.loginServer { SamsungLoginWebView(server: server) }
                    }
                    .navigationTitle("Đăng nhập Samsung")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Huỷ") { model.showLogin = false }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if model.foundTVs.isEmpty { model.scan() } }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chuẩn bị TV (làm 1 lần)").font(.headline)
            HStack {
                Text("IP iPhone:")
                Spacer()
                Text(model.iphoneIP.isEmpty ? "Chưa có Wi-Fi" : model.iphoneIP)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundColor(.green)
            }
            Group {
                Text("1. iPhone và TV dùng cùng một mạng Wi-Fi.")
                Text("2. Trên TV mở Apps (Ứng dụng), bấm lần lượt 1 2 3 4 5 trên remote (remote không có số: dùng bàn phím số trên màn hình).")
                Text("3. Bật Developer Mode = ON, ô Host PC IP nhập đúng IP iPhone ở trên, bấm OK.")
                Text("4. Tắt hẳn TV (giữ nút nguồn tới khi logo Samsung hiện lại) rồi bật lại.")
                Text("5. Nên tắt Anynet+ (HDMI-CEC) để PS5 không tự kéo TV khỏi app phụ đề.")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private var tvCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TV Samsung").font(.headline)
                Spacer()
                Button(action: { model.scan() }) {
                    if model.isScanning { ProgressView() } else { Label("Tìm TV", systemImage: "magnifyingglass") }
                }
                .disabled(model.isScanning)
            }
            ForEach(model.foundTVs) { tv in
                Button(action: { model.tvIP = tv.ip }) {
                    HStack {
                        Image(systemName: model.tvIP == tv.ip ? "checkmark.circle.fill" : "tv")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(tv.name) — \(tv.ip)").font(.subheadline.bold())
                            Text(devModeText(tv)).font(.caption).foregroundColor(devModeColor(tv))
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            // 1.23: bàn phím .decimalPad theo vùng Việt Nam chỉ có dấu PHẨY -> không gõ được IP.
            // Dùng bàn phím số + dấu chấm, và tự đổi "," thành "." nếu người dùng gõ phẩy.
            TextField("IP của TV, ví dụ 192.168.1.20", text: $model.tvIP)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .onChange(of: model.tvIP) { newValue in
                    let fixed = TVIPInput.normalize(newValue)
                    if fixed != newValue { model.tvIP = fixed }
                }
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private func devModeText(_ tv: FoundTV) -> String {
        guard let mode = tv.developerMode else { return tv.model }
        if mode != "1" { return "Developer Mode: TẮT" }
        if let ip = tv.developerIP, !ip.isEmpty {
            return ip == model.iphoneIP ? "Developer Mode: BẬT, Host PC IP đúng iPhone ✓" : "Developer Mode: BẬT, Host PC IP = \(ip) (chưa phải iPhone)"
        }
        return "Developer Mode: BẬT"
    }

    private func devModeColor(_ tv: FoundTV) -> Color {
        guard let mode = tv.developerMode else { return .secondary }
        if mode == "1" && (tv.developerIP == nil || tv.developerIP == model.iphoneIP) { return .green }
        return .orange
    }

    private var actionCard: some View {
        VStack(spacing: 10) {
            Button(action: { model.install() }) {
                HStack {
                    if model.isWorking { ProgressView().tint(.black) }
                    Text(model.isWorking ? "Đang cài..." : (model.done ? "Cài lại app TV" : "Cài app phụ đề lên TV"))
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(model.isWorking ? Color.gray : Color.green)
                .foregroundColor(.black)
                .cornerRadius(12)
            }
            .disabled(model.isWorking)
            if model.hasSavedIdentity {
                Button("Đăng nhập lại Samsung (xoá chứng chỉ đã lưu)") { model.forgetSamsungAccount() }
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .disabled(model.isWorking)
            }
            Text("Lần đầu sẽ mở trang đăng nhập tài khoản Samsung (miễn phí) để Samsung cấp chứng chỉ cho đúng TV của bạn. Chứng chỉ được lưu trong iPhone cho các lần cập nhật sau.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(line.hasPrefix("✗") ? .red : line.hasPrefix("✓") ? .green : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
    }
}


/// 1.23: chuẩn hoá chữ gõ vào ô IP: "192,168,2,3" -> "192.168.2.3", bỏ khoảng trắng và ký tự lạ
enum TVIPInput {
    static func normalize(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ch.isASCII && ch.isNumber { out.append(ch) }
            else if ch == "." || ch == "," || ch == "·" || ch == "٫" { out.append(".") }
        }
        return out
    }
}
