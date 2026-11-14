// ============================================================================
// FILE 2B: 2_VideoSourceManager.swift (TÁCH TỪ FILE 2 - PHẦN 2/2)
// PHIÊN BẢN: PS5Translator 1.23 (GHÉP ĐÔI LƯU VĨNH VIỄN TRONG KEYCHAIN + KHÔNG TỰ KHOÁ MÀN HÌNH + TỰ NỐI LẠI SAU KHI MỞ KHOÁ)
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import CryptoKit
import WebKit
import Security

/// Thông tin ghép đôi Remote Play đã lưu cho từng tài khoản PSN (mỗi tài khoản 1 cặp khoá riêng)
struct PS5LinkedProfile: Codable, Identifiable, Equatable {
    var id: String { accountBase64 }
    var accountBase64: String
    var username: String
    var numericID: String
    var registKey: String
    var rpKey: String
    var host: String
    var lastConnected: Date?
}

class VideoSourceManager: NSObject, ObservableObject {
    @Published var currentFullFrame: CGImage?

    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var isConnectedToPS5: Bool = false
    @Published var isUsingTestSimulator: Bool = false
    @Published var isReceivingRealPS5Video: Bool = false

    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user_v102") ?? "Maivy1125" {
        didSet { UserDefaults.standard.set(psnUsername, forKey: "psn_user_v102") }
    }
    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid_v102") ?? "Jpiw1lMmkmw=" {
        didSet { UserDefaults.standard.set(psnAccountIDBase64, forKey: "psn_aid_v102") }
    }
    @Published var psnNumericAccountID: String = UserDefaults.standard.string(forKey: "psn_num_id_v102") ?? "7823357644222011430" {
        didSet { UserDefaults.standard.set(psnNumericAccountID, forKey: "psn_num_id_v102") }
    }
    @Published var isAccountRemembered: Bool = UserDefaults.standard.bool(forKey: "psn_remembered_v102") {
        didSet { UserDefaults.standard.set(isAccountRemembered, forKey: "psn_remembered_v102") }
    }

    @Published var psnPinCode: String = ""
    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip_v102") ?? "192.168.2.23" {
        didSet { UserDefaults.standard.set(ps5HostIP, forKey: "ps5_ip_v102") }
    }
    @Published var discoveredPS5Name: String = UserDefaults.standard.string(forKey: "ps5_name_v102") ?? "PS5 Console"
    @Published var discoveredPS5HostID: String = UserDefaults.standard.string(forKey: "ps5_hostid_v102") ?? ""
    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 qua lõi C Chiaki-NG."

    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_real_regist_key_v102") ?? ""
    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_real_rp_key_v102") ?? ""

    /// Danh sách tài khoản đã ghép đôi (không bị xoá khi đổi tài khoản)
    @Published var linkedProfiles: [PS5LinkedProfile] = VideoSourceManager.loadProfiles()
    /// Tự kết nối lại khi PS5 ngắt phiên (đổi user bằng nút PS, rớt Wi-Fi, quay lại app...)
    @Published var autoReconnectEnabled: Bool = (UserDefaults.standard.object(forKey: "ps5_auto_reconnect_v110") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoReconnectEnabled, forKey: "ps5_auto_reconnect_v110") }
    }
    /// Giữ kết nối khi thoát app ra ngoài (phát âm thanh im lặng ở chế độ nền)
    @Published var keepAliveInBackground: Bool = (UserDefaults.standard.object(forKey: "ps5_keep_bg_v110") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(keepAliveInBackground, forKey: "ps5_keep_bg_v110")
            if !keepAliveInBackground { BackgroundKeepAlive.shared.stop() }
            else if isConnectedToPS5 || remoteSession.isRunning { BackgroundKeepAlive.shared.start() }
        }
    }

    /// 1.23: không cho iPhone tự khoá màn hình khi đang kết nối PS5 (iOS khoá máy là mất phiên Remote Play)
    @Published var preventAutoLock: Bool = (UserDefaults.standard.object(forKey: "ps5_prevent_autolock_v123") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(preventAutoLock, forKey: "ps5_prevent_autolock_v123")
            updateIdleTimer()
        }
    }
    /// 1.23: app đang ở nền / màn hình đã khoá (để phân biệt "mất kết nối do khoá máy" với "PS5 đổi tài khoản")
    private var isInBackground = false
    private var lastBackgroundAt: Date = .distantPast
    private var droppedWhileAway = false

    @Published var customDialogueRect: CGRect
    @Published var customQuestRect: CGRect

    private var timer: Timer?
    private var udpDiscoveryConn: NWConnection?
    private var rawRegistTCPConn: NWConnection?
    private var ctrlSessionTCPConn: NWConnection?
    private let remoteSession = PS5RemotePlaySession()
    private var userRequestedDisconnect = false
    /// PS5 ngắt phiên do đổi tài khoản -> chờ người dùng chọn tài khoản, không tự kết nối lại
    private var waitingForUserAccountChoice = false
    private var reconnectAttempt = 0
    private var ctrlRefusedCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var activeConnection: (ip: String, registKey: String, rpKey: String, accountBase64: String)?
    private var lastVideoFrameTime: Date = .distantPast

    override init() {
        self.customDialogueRect = VideoSourceManager.loadSavedRect(
            key: "roi_dialogue_v102",
            fallback: ROIDefaultConfig.dialogueDefaultRect
        )
        self.customQuestRect = VideoSourceManager.loadSavedRect(
            key: "roi_quest_v102",
            fallback: ROIDefaultConfig.questDefaultRect
        )
        super.init()

        let checkNorm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(
            input: psnAccountIDBase64,
            fallbackUsername: psnUsername
        )
        if checkNorm.isValidRealID {
            psnAccountIDBase64 = checkNorm.base64
            psnNumericAccountID = checkNorm.numericString
            isAccountRemembered = true
            statusLog = "✅ Đã ghi nhớ tài khoản '\(psnUsername)' (ID 8-byte: \(psnAccountIDBase64) • Số ID: \(psnNumericAccountID))."
        } else {
            psnAccountIDBase64 = "Jpiw1lMmkmw="
            psnNumericAccountID = "7823357644222011430"
            psnUsername = "Maivy1125"
            isAccountRemembered = true
        }

        _ = ps5rp_global_init()
        migrateLegacyKeysIntoProfiles()

        remoteSession.onFrame = { [weak self] img in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastVideoFrameTime = Date()
                if !self.isReceivingRealPS5Video {
                    self.isReceivingRealPS5Video = true
                    self.statusLog = "✅ Đang nhận hình ảnh trực tiếp từ PS5 (Chiaki-NG)."
                }
                self.currentFullFrame = img
            }
        }
        remoteSession.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleRemotePlayEvent(event) }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        startPS5RemoteStreamLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.scanForPS5OnLAN()
        }

        // GHI NHỚ KẾT NỐI: mở app là tự kết nối lại PS5 bằng tài khoản đã ghép đôi lần trước
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.autoConnectWithSavedProfileIfPossible(reason: "Mở app")
        }
    }

    func extractAccountIDFromSonyWebCookies(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else {
                    completion?(false)
                    return
                }
                let sonyCookies = cookies.filter {
                    $0.domain.contains("sony.com") || $0.domain.contains("playstation.net") || $0.domain.contains("playstation.com")
                }
                guard !sonyCookies.isEmpty else {
                    completion?(false)
                    return
                }

                for cookie in sonyCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }

                self.fetchBasicProfileWithCookies(sonyCookies) { foundDirect in
                    if foundDirect {
                        completion?(true)
                        return
                    }

                    let silentAuthURLStr = "https://ca.account.sony.com/api/authz/v3/oauth/authorize?access_type=offline&client_id=09515159-7237-4370-9b40-3806e67c0891&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&response_type=code&scope=psn:mobile.v2.core%20psn:clientapp&prompt=none"
                    guard let url = URL(string: silentAuthURLStr) else {
                        completion?(false)
                        return
                    }

                    let config = URLSessionConfiguration.default
                    config.httpShouldSetCookies = true
                    config.httpCookieAcceptPolicy = .always

                    let delegate = SilentOAuthRedirectCatcher { [weak self] code in
                        guard let self = self, let code = code else {
                            completion?(false)
                            return
                        }
                        self.exchangeSonyCodeForRealAccountID(code: code, completion: completion)
                    }

                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    var req = URLRequest(url: url)
                    let cookieHeader = HTTPCookie.requestHeaderFields(with: sonyCookies)
                    for (k, v) in cookieHeader {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                    session.dataTask(with: req).resume()
                }
            }
        }
    }

    private func fetchBasicProfileWithCookies(_ cookies: [HTTPCookie], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://web.np.playstation.com/api/basicProfile/v1/profile/users/me") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in cookieHeader {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("https://www.playstation.com/", forHTTPHeaderField: "Referer")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let extracted = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) else {
                completion(false)
                return
            }
            DispatchQueue.main.async {
                let user = extracted.onlineID.isEmpty ? self.psnUsername : extracted.onlineID
                self.saveRememberedAccount(username: user, accountIDBase64: extracted.base64ID, numericID: extracted.numericID)
                completion(true)
            }
        }.resume()
    }

    func exchangeSonyCodeForRealAccountID(code: String, completion: ((Bool) -> Void)? = nil) {
        guard let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token") else {
            completion?(false)
            return
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=", forHTTPHeaderField: "Authorization")

        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let body = "grant_type=authorization_code&code=\(encodedCode)&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&token_format=jwt"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data else {
                completion?(false)
                return
            }

            if let directFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                DispatchQueue.main.async {
                    let user = directFound.onlineID.isEmpty ? self.psnUsername : directFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: directFound.base64ID, numericID: directFound.numericID)
                    completion?(true)
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                completion?(false)
                return
            }

            if let jwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(accessToken) {
                DispatchQueue.main.async {
                    let user = jwtFound.onlineID.isEmpty ? self.psnUsername : jwtFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: jwtFound.base64ID, numericID: jwtFound.numericID)
                    completion?(true)
                }
                return
            }
            if let idToken = json["id_token"] as? String,
               let idJwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(idToken) {
                DispatchQueue.main.async {
                    let user = idJwtFound.onlineID.isEmpty ? self.psnUsername : idJwtFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: idJwtFound.base64ID, numericID: idJwtFound.numericID)
                    completion?(true)
                }
                return
            }

            self.fetchPSNAccountIDMultiEndpoint(accessToken: accessToken) { onlineID, base64ID, numericID in
                DispatchQueue.main.async {
                    let user = onlineID.isEmpty ? self.psnUsername : onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: base64ID, numericID: numericID)
                    completion?(true)
                }
            } onFailure: {
                completion?(false)
            }
        }.resume()
    }

    func fetchPSNAccountIDMultiEndpoint(
        accessToken: String,
        onSuccess: @escaping (String, String, String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        let endpoints: [(url: String, authHeader: String)] = [
            ("https://dms.api.playstation.com/api/v1/devices/accounts/me", "Bearer \(accessToken)"),
            ("https://ca.account.sony.com/api/v1/oauth/token/\(accessToken)", "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="),
            ("https://us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=accountId,onlineId", "Bearer \(accessToken)"),
            ("https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles", "Bearer \(accessToken)"),
            ("https://web.np.playstation.com/api/basicProfile/v1/profile/users/me", "Bearer \(accessToken)")
        ]

        func tryEndpoint(at index: Int) {
            guard index < endpoints.count else {
                onFailure()
                return
            }
            let current = endpoints[index]
            guard let url = URL(string: current.url) else {
                tryEndpoint(at: index + 1)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 6.0
            req.setValue(current.authHeader, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data = data,
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    onSuccess(found.onlineID, found.base64ID, found.numericID)
                    return
                }
                tryEndpoint(at: index + 1)
            }.resume()
        }

        tryEndpoint(at: 0)
    }

    func saveRememberedAccount(username: String, accountIDBase64: String, numericID: String = "") {
        let cleanUser = username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !cleanUser.isEmpty && !cleanUser.allSatisfy({ $0.isNumber }) {
            self.psnUsername = cleanUser
        }

        let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(
            input: accountIDBase64.isEmpty ? cleanUser : accountIDBase64,
            fallbackUsername: self.psnUsername
        )
        guard norm.isValidRealID else {
            self.statusLog = "⚠️ Mã Account ID chưa phải mã 8-byte thật từ Sony. Hãy bấm 'Đăng nhập Sony' để lấy mã chính xác."
            return
        }

        self.psnAccountIDBase64 = norm.base64
        self.psnNumericAccountID = numericID.isEmpty ? norm.numericString : numericID
        self.isAccountRemembered = true

        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user_v102")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid_v102")
        UserDefaults.standard.set(self.psnNumericAccountID, forKey: "psn_num_id_v102")
        UserDefaults.standard.set(true, forKey: "psn_remembered_v102")
        UserDefaults.standard.synchronize()

        self.statusLog = "✅ Đã lưu TK '\(self.psnUsername)' • Số ID Sony: \(self.psnNumericAccountID) • Mã 8-byte: \(self.psnAccountIDBase64)"
    }

    // ĐÃ SỬA (1.10): "Xoá & Đổi TK" chỉ xoá ô nhập để thêm tài khoản khác.
    // Khoá ghép đôi của các tài khoản đã liên kết VẪN ĐƯỢC GIỮ trong linkedProfiles
    // (trước đây xoá mất khoá -> app "không ghi nhớ" lần kết nối).
    func clearRememberedAccount() {
        psnAccountIDBase64 = ""
        psnNumericAccountID = ""
        savedRegistKey = ""
        savedRPKey = ""
        isAccountRemembered = false
        UserDefaults.standard.removeObject(forKey: "psn_aid_v102")
        UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")
        UserDefaults.standard.removeObject(forKey: "chiaki_real_regist_key_v102")
        UserDefaults.standard.removeObject(forKey: "chiaki_real_rp_key_v102")
        UserDefaults.standard.set(false, forKey: "psn_remembered_v102")

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                WKWebsiteDataStore.default().httpCookieStore.delete(cookie, completionHandler: nil)
            }
        }
        statusLog = "Đã xoá ô tài khoản & Cookie. Các tài khoản đã liên kết vẫn được giữ. Hãy bấm 'Đăng nhập Sony' để thêm tài khoản khác."
    }

    func lookupAccountIDByPSNUsername() {
        let targetUser = psnUsername.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !targetUser.isEmpty else {
            statusLog = "⚠️ Vui lòng nhập Online ID của tài khoản PSN (VD: Maivy1125) trước."
            return
        }

        let directCheck = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: targetUser, fallbackUsername: "Maivy1125")
        if directCheck.isValidRealID {
            saveRememberedAccount(username: "Maivy1125", accountIDBase64: directCheck.base64, numericID: directCheck.numericString)
            return
        }

        statusLog = "Đang tra cứu mã Account ID 8-byte thật của Online ID '\(targetUser)'..."

        guard let encodedUser = targetUser.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: "https://psn.flipscreen.games/search.php?username=\(encodedUser)") else {
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 7.0
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            if let data = data,
               let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                DispatchQueue.main.async {
                    let resolvedUser = found.onlineID.isEmpty ? targetUser : found.onlineID
                    self.saveRememberedAccount(username: resolvedUser, accountIDBase64: found.base64ID, numericID: found.numericID)
                }
                return
            }

            self.extractAccountIDFromSonyWebCookies { [weak self] ok in
                guard let self = self else { return }
                if !ok {
                    DispatchQueue.main.async {
                        self.statusLog = "⚠️ Không tìm thấy Online ID '\(targetUser)' công khai. Hãy bấm nút 'Đăng nhập Sony' màu xanh bên dưới để lấy chính xác Account ID 8-byte!"
                    }
                }
            }
        }.resume()
    }

    func getNormalizedROIRect(for mode: ROIMode) -> CGRect {
        switch mode {
        case .fullScreen:
            return ROIDefaultConfig.fullScreenRect
        case .dialogueOnly:
            return customDialogueRect
        case .questAndMenu:
            return customQuestRect
        }
    }

    func updateCustomROIRect(for mode: ROIMode, newRect: CGRect) {
        let clampedW = max(0.15, min(0.96, newRect.width))
        let clampedH = max(0.08, min(0.92, newRect.height))
        let clampedX = max(0.02, min(0.98 - clampedW, newRect.origin.x))
        let clampedY = max(0.02, min(0.98 - clampedH, newRect.origin.y))
        let safeRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)

        switch mode {
        case .fullScreen:
            break
        case .dialogueOnly:
            customDialogueRect = safeRect
            VideoSourceManager.saveRect(safeRect, key: "roi_dialogue_v102")
        case .questAndMenu:
            customQuestRect = safeRect
            VideoSourceManager.saveRect(safeRect, key: "roi_quest_v102")
        }
    }

    func resetROIRectToDefault(for mode: ROIMode) {
        switch mode {
        case .fullScreen:
            break
        case .dialogueOnly:
            customDialogueRect = ROIDefaultConfig.dialogueDefaultRect
            VideoSourceManager.saveRect(customDialogueRect, key: "roi_dialogue_v102")
        case .questAndMenu:
            customQuestRect = ROIDefaultConfig.questDefaultRect
            VideoSourceManager.saveRect(customQuestRect, key: "roi_quest_v102")
        }
    }

    private static func saveRect(_ rect: CGRect, key: String) {
        let array: [Double] = [
            Double(rect.origin.x),
            Double(rect.origin.y),
            Double(rect.size.width),
            Double(rect.size.height)
        ]
        UserDefaults.standard.set(array, forKey: key)
    }

    private static func loadSavedRect(key: String, fallback: CGRect) -> CGRect {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else {
            return fallback
        }
        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
    }

    func cropFrameToSmartROI(fullImage: CGImage, mode: ROIMode) -> CGImage? {
        let width = CGFloat(fullImage.width)
        let height = CGFloat(fullImage.height)
        let norm = getNormalizedROIRect(for: mode)
        let targetRect = CGRect(
            x: width * norm.origin.x,
            y: height * norm.origin.y,
            width: width * norm.size.width,
            height: height * norm.size.height
        )
        return fullImage.cropping(to: targetRect.integral)
    }

    func scanForPS5OnLAN() {
        let cleanIP = ps5HostIP.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        connectionState = .scanningLAN
        statusLog = "Chiaki DDP: Đang dò máy PS5 tại \(cleanIP):9302..."

        let host = NWEndpoint.Host(cleanIP.isEmpty ? "255.255.255.255" : cleanIP)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        udpDiscoveryConn?.cancel()
        udpDiscoveryConn = NWConnection(host: host, port: port, using: .udp)

        var didRespond = false
        udpDiscoveryConn?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let srchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"
                self.udpDiscoveryConn?.send(content: srchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))

                self.udpDiscoveryConn?.receiveMessage { data, _, _, _ in
                    guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
                    didRespond = true
                    DispatchQueue.main.async {
                        let hostName = self.extractHeader(from: text, key: "host-name") ?? "PS5 Console"
                        let hostId = self.extractHeader(from: text, key: "host-id") ?? "PS5-LAN"
                        self.discoveredPS5Name = hostName
                        self.discoveredPS5HostID = hostId
                        UserDefaults.standard.set(hostName, forKey: "ps5_name_v102")
                        UserDefaults.standard.set(hostId, forKey: "ps5_hostid_v102")

                        if text.contains("200 Ok") {
                            self.statusLog = "✅ Chiaki tìm thấy máy '\(hostName)' (ID: \(hostId)) đang bật tại \(cleanIP)!"
                        } else if text.contains("620 Server Standby") {
                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ. Đang gửi lệnh WAKEUP..."
                            self.sendChiakiWakeupPacket(ip: cleanIP)
                        }
                        if !self.isConnectedToPS5 {
                            self.connectionState = .disconnected
                        }
                    }
                }
            }
        }
        udpDiscoveryConn?.start(queue: .global())

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            if !didRespond && self.connectionState == .scanningLAN {
                self.connectionState = self.isConnectedToPS5 ? .connected(hostName: self.discoveredPS5Name) : .disconnected
            }
        }
    }

    func sendChiakiWakeupPacket(ip: String) {
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                // ĐÃ SỬA (1.10): đúng định dạng chiaki-ng discovery.c. user-credential là số thập phân
                // của chuỗi ASCII hex trong rp_regist_key (KHÔNG phải Account ID).
                guard let credential = self.wakeupCredential() else {
                    conn.cancel()
                    return
                }
                let wakePacket = "WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\nuser-credential:\(credential)\ndevice-discovery-protocol-version:00030010\n"
                conn.send(content: wakePacket.data(using: .utf8), completion: .contentProcessed({ _ in
                    conn.cancel()
                }))
            }
        }
        conn.start(queue: .global())
    }

    private func wakeupCredential() -> UInt64? {
        let key = activeConnection?.registKey ?? savedRegistKey
        guard ChiakiEmbeddedCore.shared.isValidRegistKey(key) else { return nil }
        let bytes = [UInt8](ChiakiEmbeddedCore.shared.parseRegistKeyTo16Bytes(key))
        let ascii = bytes.prefix { $0 != 0 }
        guard !ascii.isEmpty, ascii.count <= 8, let str = String(bytes: ascii, encoding: .ascii) else { return nil }
        return UInt64(str, radix: 16)
    }

    private func extractHeader(from text: String, key: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
                             .replacingOccurrences(of: "\0", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: CharacterSet.whitespaces) == key.lowercased() {
                var value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\"' ")))
                if let nextToken = value.range(of: " RP-", options: .caseInsensitive) {
                    value = String(value[..<nextToken.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let nextToken = value.range(of: " PS5-", options: .caseInsensitive) {
                    value = String(value[..<nextToken.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }
        }
        return nil
    }

    func connectToPS5(username: String, pinCode: String, ip: String) {
        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)
    }

    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {
        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        self.ps5HostIP = cleanIP

        var parsed = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: username)
        if !parsed.isValidRealID {
            parsed = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: username, fallbackUsername: "Maivy1125")
        }

        guard parsed.isValidRealID else {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Chưa có Account ID 8-byte thật")
            self.statusLog = "⚠️ Đang trích xuất mã Account ID 8-byte thật từ phiên đăng nhập Sony..."
            self.extractAccountIDFromSonyWebCookies { [weak self] ok in
                guard let self = self else { return }
                if ok && cleanPIN.count == 8 {
                    self.performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)
                }
            }
            return
        }

        saveRememberedAccount(username: username, accountIDBase64: parsed.base64, numericID: parsed.numericString)

        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Chiaki-NG Core: Đang gửi gói ghép đôi 587-byte chuẩn PS5 (PIN: \(cleanPIN), ID: \(parsed.base64)) tới \(cleanIP):9295..."
            performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: parsed.base64)
        } else if let profile = linkedProfiles.first(where: { $0.accountBase64 == parsed.base64 }) {
            connectionState = .connectingStream
            statusLog = "Chiaki-NG Core: Đang mở phiên Remote Play đã lưu của '\(profile.username)' với PS5 (\(cleanIP))..."
            startChiakiNativeSession(ip: cleanIP, registKey: profile.registKey, rpKey: profile.rpKey, accountBase64: profile.accountBase64)
        } else if !savedRegistKey.isEmpty && !savedRPKey.isEmpty {
            connectionState = .connectingStream
            statusLog = "Chiaki-NG Core: Đang mở phiên Remote Play đã lưu với PS5 (\(cleanIP))..."
            startChiakiNativeSession(ip: cleanIP, registKey: savedRegistKey, rpKey: savedRPKey, accountBase64: parsed.base64)
        } else {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Chưa nhập mã PIN 8 số")
            self.statusLog = "⚠️ Vui lòng nhập 8 chữ số Mã PIN đang hiển thị trên màn hình PS5."
        }
    }

    // ĐÃ SỬA: Chỉ gửi duy nhất 1 luồng UDP SRC3 chuẩn trên cổng 9295 (fallback sang cổng động nếu bận)
    // để không làm PS5 huỷ phiên chờ mã PIN
    private func performRawSocketChiakiRegistration(ip: String, pin: String, accountIDBase64: String) {
        rawRegistTCPConn?.cancel()

        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }
        let src3Packet = ChiakiEmbeddedCore.shared.buildRegistSearchPacketPS5()

        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true
        udpParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: port)

        let udpSearchConn = NWConnection(host: host, port: port, using: udpParams)
        var didStartTCP = false

        let launchTCPRegist = { [weak self] in
            guard let self = self, !didStartTCP else { return }
            didStartTCP = true
            udpSearchConn.cancel()
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) {
                self.sendTCPRegistPayload(ip: ip, pin: pin, accountIDBase64: accountIDBase64)
            }
        }

        udpSearchConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                udpSearchConn.send(content: src3Packet, completion: .contentProcessed({ _ in }))
                udpSearchConn.receiveMessage { _, _, _, _ in
                    launchTCPRegist()
                }
            case .failed:
                // Nếu cổng UDP 9295 đang bận trên iOS, gửi SRC3 qua socket UDP tiêu chuẩn
                let fallbackUDP = NWConnection(host: host, port: port, using: .udp)
                fallbackUDP.stateUpdateHandler = { fbState in
                    if case .ready = fbState {
                        fallbackUDP.send(content: src3Packet, completion: .contentProcessed({ _ in
                            fallbackUDP.cancel()
                            launchTCPRegist()
                        }))
                    } else if case .failed = fbState {
                        fallbackUDP.cancel()
                        launchTCPRegist()
                    }
                }
                fallbackUDP.start(queue: .global(qos: .userInteractive))
            default:
                break
            }
        }
        udpSearchConn.start(queue: .global(qos: .userInteractive))

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.30) {
            launchTCPRegist()
        }
    }

    // ĐÃ SỬA: Gom đủ toàn bộ các mảnh gói tin TCP phản hồi từ PS5 trước khi giải mã
    private func receiveFullHTTPResponse(
        from conn: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping (Data) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                completion(accumulated)
                return
            }
            var buffer = accumulated
            if let chunk = chunk, !chunk.isEmpty {
                buffer.append(chunk)
            }

            let separator = Data("\r\n\r\n".utf8)
            if let range = buffer.range(of: separator) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let bodyCount = buffer.count - range.upperBound
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""

                if let clStr = self.extractHeader(from: headerStr, key: "Content-Length"),
                   let expectedLen = Int(clStr) {
                    if bodyCount >= expectedLen {
                        completion(buffer)
                        return
                    }
                } else if !headerStr.contains("200 OK") && !headerStr.contains("200 Ok") {
                    completion(buffer)
                    return
                } else if bodyCount >= 96 {
                    completion(buffer)
                    return
                }
            }

            if isComplete || error != nil {
                completion(buffer)
            } else {
                self.receiveFullHTTPResponse(from: conn, accumulated: buffer, completion: completion)
            }
        }
    }

    private func sendTCPRegistPayload(ip: String, pin: String, accountIDBase64: String) {
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        let (payload587, aesKey, iv) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload480(
            pinString: pin,
            accountIDBase64: accountIDBase64
        )
        let rawHTTPPacket = ChiakiEmbeddedCore.shared.buildRawHTTPRegistRequest(ip: ip, payload: payload587)

        let tcpConn = NWConnection(host: host, port: port, using: .tcp)
        rawRegistTCPConn = tcpConn
        var didComplete = false

        tcpConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                tcpConn.send(content: rawHTTPPacket, completion: .contentProcessed({ _ in
                    self.receiveFullHTTPResponse(from: tcpConn) { data in
                        guard !didComplete else { return }
                        didComplete = true
                        tcpConn.cancel()

                        DispatchQueue.main.async {
                            guard !data.isEmpty else {
                                self.isConnectedToPS5 = false
                                self.connectionState = .error(message: "PS5 đóng kết nối cổng 9295")
                                self.statusLog = "❌ Máy PS5 (\(ip)) không phản hồi gói ghép đôi. Hãy kiểm tra PS5 đang mở màn hình đếm ngược mã PIN 8 chữ số."
                                return
                            }

                            let separator = Data("\r\n\r\n".utf8)
                            let headerEndRange = data.range(of: separator)
                            let headerData = headerEndRange != nil ? data.subdata(in: 0..<headerEndRange!.lowerBound) : data
                            let bodyData = headerEndRange != nil ? data.subdata(in: headerEndRange!.upperBound..<data.count) : Data()
                            let headerStr = String(data: headerData, encoding: .utf8) ?? ""

                            if headerStr.contains("200 OK") || headerStr.contains("200 Ok") {
                                let decryptedBody = ChiakiEmbeddedCore.shared.decryptRegistResponse(
                                    cipherData: bodyData,
                                    aesKey: aesKey,
                                    iv: iv
                                ) ?? ""

                                let regKey = self.extractHeader(from: decryptedBody, key: "PS5-RegistKey")
                                    ?? self.extractHeader(from: decryptedBody, key: "RP-RegistKey")
                                    ?? self.extractHeader(from: headerStr, key: "PS5-RegistKey")
                                    ?? self.extractHeader(from: headerStr, key: "RP-RegistKey")
                                    ?? ""
                                let rpKey = self.extractHeader(from: decryptedBody, key: "RP-Key")
                                    ?? self.extractHeader(from: headerStr, key: "RP-Key")
                                    ?? ""

                                guard !regKey.isEmpty && !rpKey.isEmpty else {
                                    self.statusLog = "⚠️ PS5 trả về 200 OK nhưng chưa giải mã được RP-Key (Body: \(bodyData.count)B). Đang thử lại..."
                                    return
                                }

                                let cleanRegKey = regKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\"' ")))
                                let cleanRPKey = rpKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\"' ")))

                                guard ChiakiEmbeddedCore.shared.isValidRegistKey(cleanRegKey),
                                      ChiakiEmbeddedCore.shared.parseRPKeyBytes(cleanRPKey) != nil else {
                                    self.isConnectedToPS5 = false
                                    self.connectionState = .error(message: "Giải mã khoá ghép đôi bị sai")
                                    self.statusLog = "❌ PS5 trả 200 OK nhưng khoá giải mã ra không hợp lệ (RegistKey: \(cleanRegKey.count) ký tự, RP-Key: \(cleanRPKey.count) ký tự). Hãy lấy mã PIN mới và ghép đôi lại."
                                    return
                                }

                                self.savedRegistKey = cleanRegKey
                                self.savedRPKey = cleanRPKey
                                UserDefaults.standard.set(cleanRegKey, forKey: "chiaki_real_regist_key_v102")
                                UserDefaults.standard.set(cleanRPKey, forKey: "chiaki_real_rp_key_v102")
                                UserDefaults.standard.synchronize()
                                self.upsertProfile(accountBase64: accountIDBase64, registKey: cleanRegKey, rpKey: cleanRPKey, host: ip)

                                self.psnPinCode = ""
                                self.connectionState = .connectingStream
                                self.statusLog = "✅ Ghép đôi PIN thành công (HTTP 200 OK)! Đang đợi PS5 lưu thiết bị mới (3 giây)..."

                                // Chờ 3s để PS5 lưu thiết bị mới và đóng socket rgst trước khi mở phiên init
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                                    guard let self = self else { return }
                                    self.statusLog = "Chiaki-NG: Đang mở phiên Remote Play với PS5..."
                                    self.startChiakiNativeSession(ip: ip, registKey: cleanRegKey, rpKey: cleanRPKey, accountBase64: accountIDBase64)
                                }
                            } else {
                                let reasonCode = self.extractHeader(from: headerStr, key: "RP-Application-Reason") ?? "HTTP 403"
                                self.isConnectedToPS5 = false
                                self.connectionState = .error(message: "PS5 từ chối (\(reasonCode))")
                                self.statusLog = "❌ Máy PS5 (\(ip)) từ chối ghép đôi (Mã: \(reasonCode)). Hãy thoát màn hình mã PIN trên PS5 rồi vào lại lấy mã PIN 8 số mới."
                            }
                        }
                    }
                }))
            case .failed(let err):
                guard !didComplete else { return }
                didComplete = true
                DispatchQueue.main.async {
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: err.localizedDescription)
                    self.statusLog = "❌ Không kết nối được cổng 9295 của PS5 (\(ip)): \(err.localizedDescription)"
                }
            default:
                break
            }
        }
        tcpConn.start(queue: .global(qos: .userInteractive))
    }

    // =========================================================================
    // 1.10: PHIÊN REMOTE PLAY CHIAKI-NG ĐẦY ĐỦ (thay cho bản bắt tay viết tay cũ)
    // =========================================================================

    private func startChiakiNativeSession(ip: String, registKey: String, rpKey: String, accountBase64: String) {
        let core = ChiakiEmbeddedCore.shared
        guard core.isValidRegistKey(registKey), let morning = core.parseRPKeyBytes(rpKey) else {
            isConnectedToPS5 = false
            connectionState = .error(message: "Khoá ghép đôi không hợp lệ")
            statusLog = "❌ Khoá ghép đôi đã lưu bị hỏng. Hãy nhập mã PIN 8 số mới để ghép đôi lại tài khoản này."
            return
        }
        let registBytes = [UInt8](core.parseRegistKeyTo16Bytes(registKey))
        let accountBytes: [UInt8]? = Data(base64Encoded: accountBase64).flatMap { $0.count == 8 ? [UInt8]($0) : nil }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        userRequestedDisconnect = false
        waitingForUserAccountChoice = false
        activeConnection = (ip, registKey, rpKey, accountBase64)
        ps5HostIP = ip
        connectionState = .connectingStream
        isReceivingRealPS5Video = false

        let result = remoteSession.start(host: ip, registKey16: registBytes, morning16: morning, accountID8: accountBytes,
                                         width: 1280, height: 720, fps: 30, bitrate: 10000)
        if result != 0 {
            isConnectedToPS5 = false
            connectionState = .error(message: "Không khởi động được lõi Chiaki (\(result))")
            statusLog = "❌ Không khởi động được phiên Chiaki-NG (mã \(result)). Kiểm tra iPhone và PS5 cùng mạng Wi-Fi."
            scheduleReconnect(reason: "Lỗi khởi động phiên")
            return
        }
        if keepAliveInBackground { BackgroundKeepAlive.shared.start() }
    }

    private func handleRemotePlayEvent(_ event: PS5RemotePlaySession.Event) {
        switch event {
        case .connected:
            reconnectAttempt = 0
            ctrlRefusedCount = 0
            isConnectedToPS5 = true
            isUsingTestSimulator = false
            let hostTitle = discoveredPS5Name.isEmpty ? "PS5 Console" : discoveredPS5Name
            let ip = activeConnection?.ip ?? ps5HostIP
            connectionState = .connected(hostName: "\(hostTitle) (\(ip))")
            droppedWhileAway = false
            updateIdleTimer()
            statusLog = "✅ Đã kết nối Remote Play với \(hostTitle) (\(ip)). Đang chờ khung hình đầu tiên..."
            if let acc = activeConnection?.accountBase64,
               let idx = linkedProfiles.firstIndex(where: { $0.accountBase64 == acc }) {
                linkedProfiles[idx].lastConnected = Date()
                linkedProfiles[idx].host = ip
                saveProfiles()
                UserDefaults.standard.set(acc, forKey: "ps5_last_profile_v110")
            }

        case .quit(let code, let message):
            isConnectedToPS5 = false
            isReceivingRealPS5Video = false
            updateIdleTimer()
            if userRequestedDisconnect || code == PS5RP_QUIT_STOPPED {
                connectionState = .disconnected
                return
            }
            // 1.23: phiên rớt khi iPhone đang khoá màn hình / ở nền (hoặc vừa quay lại < 90 giây):
            // đây KHÔNG phải đổi tài khoản trên PS5 -> mở lại app là tự kết nối lại, không phải bấm gì.
            if code != 9 && (isInBackground || Date().timeIntervalSince(lastBackgroundAt) < 90) {
                waitingForUserAccountChoice = false
                droppedWhileAway = true
                connectionState = .error(message: "Mất kết nối khi khoá màn hình")
                if isInBackground && !keepAliveInBackground {
                    statusLog = "🔄 Mất kết nối PS5 khi màn hình khoá. Mở lại app sẽ tự kết nối lại."
                } else {
                    scheduleReconnect(reason: "Mất kết nối khi khoá màn hình")
                }
                return
            }
            // 9 = CTRL_CONNECTION_REFUSED: khoá sai / thiết bị bị gỡ liên kết trên PS5
            if code == 9 {
                ctrlRefusedCount += 1
                if ctrlRefusedCount >= 3 {
                    connectionState = .error(message: "PS5 từ chối khoá ghép đôi")
                    statusLog = "❌ PS5 từ chối khoá ghép đôi 3 lần (\(message)). Có thể iPhone đã bị gỡ khỏi 'Thiết bị đã liên kết' trên PS5. Hãy nhập mã PIN mới để ghép đôi lại."
                    return
                }
            }
            // PS5 chủ động ngắt phiên: thường do bấm nút PS đổi sang tài khoản khác. KHÔNG tự kết nối lại
            // bằng tài khoản cũ (sẽ kéo PS5 về lại tài khoản phụ) -> để người dùng chạm chọn tài khoản muốn dùng.
            if code == PS5RP_QUIT_REMOTE_DISCONNECTED {
                waitingForUserAccountChoice = true
                reconnectWorkItem?.cancel()
                connectionState = .error(message: "PS5 đã ngắt phiên Remote Play")
                let others = linkedProfiles.filter { $0.accountBase64 != activeConnection?.accountBase64 }
                if others.isEmpty {
                    statusLog = "⚠️ PS5 đã ngắt phiên (thường do bấm nút PS đổi tài khoản). Sony chỉ cho Remote Play bằng đúng tài khoản đang kết nối. Muốn xem tài khoản chính: trên PS5 mở tài khoản chính > Cài đặt > Hệ thống > Chơi từ xa > Liên kết thiết bị, rồi nhập mã PIN vào app để liên kết thêm tài khoản chính."
                } else {
                    statusLog = "⚠️ PS5 đã ngắt phiên (đổi tài khoản). Mở 'Liên kết máy PS5' và chạm vào tài khoản đang dùng trên PS5 (\(others.map { $0.username }.joined(separator: ", "))) để kết nối lại ngay, không cần PIN."
                }
                return
            }
            let friendly: String
            switch code {
            case PS5RP_QUIT_REMOTE_DISCONNECTED:
                friendly = "PS5 đã ngắt phiên"
            case PS5RP_QUIT_REMOTE_SHUTDOWN:
                friendly = "PS5 đã tắt hoặc vào chế độ nghỉ"
            case 4:
                friendly = "PS5 đang có thiết bị khác Remote Play"
            case 3, 8:
                friendly = "Không kết nối được tới PS5"
            default:
                friendly = message
            }
            connectionState = .error(message: friendly)
            scheduleReconnect(reason: friendly)

        case .log(let level, let message):
            // Chỉ hiển thị lỗi/cảnh báo quan trọng khi chưa có hình
            if level == 1 && !isReceivingRealPS5Video && !message.isEmpty {
                statusLog = "Chiaki-NG: \(message)"
            }

        case .loginPinRequested:
            statusLog = "⚠️ Tài khoản trên PS5 đang bật mã đăng nhập (Login Passcode). Hãy tắt mã đăng nhập trong Cài đặt > Người dùng và tài khoản > Đăng nhập trên PS5 rồi thử lại."
            remoteSession.stop()

        case .nickname(let name):
            if !name.isEmpty {
                discoveredPS5Name = name
                UserDefaults.standard.set(name, forKey: "ps5_name_v102")
            }
        }
    }

    /// Tự kết nối lại với thời gian chờ tăng dần (3s, 5s, 8s, 13s, 20s, rồi 30s)
    private func scheduleReconnect(reason: String) {
        guard autoReconnectEnabled, !userRequestedDisconnect, !waitingForUserAccountChoice, let conn = activeConnection else {
            statusLog = "⚠️ \(reason). Bấm 'Liên kết máy PS5' để kết nối lại."
            return
        }
        reconnectWorkItem?.cancel()
        let delays: [Double] = [3, 5, 8, 13, 20, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        statusLog = "🔄 \(reason). Tự kết nối lại sau \(Int(delay)) giây (lần \(reconnectAttempt))..."

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.userRequestedDisconnect, !self.remoteSession.isRunning else { return }
            self.sendChiakiWakeupPacket(ip: conn.ip)
            self.startChiakiNativeSession(ip: conn.ip, registKey: conn.registKey, rpKey: conn.rpKey, accountBase64: conn.accountBase64)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Mở app / quay lại app: tự kết nối bằng tài khoản đã ghép đôi gần nhất
    func autoConnectWithSavedProfileIfPossible(reason: String) {
        guard autoReconnectEnabled, !userRequestedDisconnect, !waitingForUserAccountChoice, !remoteSession.isRunning, !isConnectedToPS5 else { return }
        guard let profile = preferredProfile() else { return }
        let ip = ps5HostIP.isEmpty ? profile.host : ps5HostIP
        guard !ip.isEmpty else { return }
        applyProfileToFields(profile)
        statusLog = "🔄 \(reason): đang tự kết nối PS5 (\(ip)) bằng tài khoản '\(profile.username)'..."
        // 1.23: PS5 đang nghỉ (Rest Mode) -> đánh thức trước bằng khoá đã ghép đôi (không cần PIN)
        sendChiakiWakeupPacket(ip: ip)
        startChiakiNativeSession(ip: ip, registKey: profile.registKey, rpKey: profile.rpKey, accountBase64: profile.accountBase64)
    }

    /// Chọn tài khoản đã liên kết và kết nối ngay (không cần PIN)
    func connectWithProfile(_ profile: PS5LinkedProfile) {
        applyProfileToFields(profile)
        UserDefaults.standard.set(profile.accountBase64, forKey: "ps5_last_profile_v110")
        let ip = ps5HostIP.isEmpty ? profile.host : ps5HostIP
        userRequestedDisconnect = false
        reconnectAttempt = 0
        statusLog = "Chiaki-NG: Đang kết nối PS5 (\(ip)) bằng tài khoản '\(profile.username)'..."
        remoteSession.stop { [weak self] in
            DispatchQueue.main.async {
                self?.startChiakiNativeSession(ip: ip, registKey: profile.registKey, rpKey: profile.rpKey, accountBase64: profile.accountBase64)
            }
        }
    }

    func removeProfile(_ profile: PS5LinkedProfile) {
        linkedProfiles.removeAll { $0.accountBase64 == profile.accountBase64 }
        saveProfiles()
    }

    @objc private func appDidBecomeActive() {
        let wasAway = isInBackground
        isInBackground = false
        updateIdleTimer()
        guard autoReconnectEnabled, !userRequestedDisconnect else { return }
        // Quay lại app / mở khoá màn hình: nếu phiên đã rớt thì kết nối lại ngay
        if !remoteSession.isRunning && !isConnectedToPS5 && (!waitingForUserAccountChoice || droppedWhileAway) {
            reconnectAttempt = 0
            if activeConnection != nil {
                scheduleReconnectNow()
            } else {
                autoConnectWithSavedProfileIfPossible(reason: "Quay lại app")
            }
        } else if isConnectedToPS5 || remoteSession.isRunning {
            remoteSession.requestKeyframe()
            // 1.23: phiên "còn sống" nhưng không còn hình (socket bị iOS cắt khi khoá máy) -> tự khởi động lại
            guard wasAway else { return }
            let resumedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, !self.isInBackground, !self.userRequestedDisconnect,
                      let conn = self.activeConnection,
                      self.lastVideoFrameTime < resumedAt else { return }
                self.statusLog = "🔄 Không còn hình sau khi mở khoá màn hình: đang kết nối lại PS5..."
                self.isConnectedToPS5 = false
                self.isReceivingRealPS5Video = false
                self.remoteSession.stop { [weak self] in
                    DispatchQueue.main.async {
                        self?.startChiakiNativeSession(ip: conn.ip, registKey: conn.registKey,
                                                       rpKey: conn.rpKey, accountBase64: conn.accountBase64)
                    }
                }
            }
        }
    }

    @objc private func appWillResignActive() {
        lastBackgroundAt = Date()
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
        lastBackgroundAt = Date()
        if !keepAliveInBackground {
            BackgroundKeepAlive.shared.stop()
        } else if isConnectedToPS5 || remoteSession.isRunning {
            BackgroundKeepAlive.shared.start()
        }
    }

    /// 1.23: giữ màn hình luôn sáng khi đang kết nối / đang kết nối lại PS5
    func updateIdleTimer() {
        let keepAwake = preventAutoLock && (isConnectedToPS5 || remoteSession.isRunning || activeConnection != nil)
            && !userRequestedDisconnect
        DispatchQueue.main.async {
            if UIApplication.shared.isIdleTimerDisabled != keepAwake {
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }
        }
    }

    private func scheduleReconnectNow() {
        guard let conn = activeConnection else { return }
        reconnectWorkItem?.cancel()
        statusLog = "🔄 Quay lại app: đang kết nối lại PS5..."
        startChiakiNativeSession(ip: conn.ip, registKey: conn.registKey, rpKey: conn.rpKey, accountBase64: conn.accountBase64)
    }

    private func preferredProfile() -> PS5LinkedProfile? {
        if let last = UserDefaults.standard.string(forKey: "ps5_last_profile_v110"),
           let p = linkedProfiles.first(where: { $0.accountBase64 == last }) {
            return p
        }
        if let p = linkedProfiles.first(where: { $0.accountBase64 == psnAccountIDBase64 }) {
            return p
        }
        return linkedProfiles.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }.first
    }

    private func applyProfileToFields(_ profile: PS5LinkedProfile) {
        psnUsername = profile.username
        psnAccountIDBase64 = profile.accountBase64
        psnNumericAccountID = profile.numericID
        isAccountRemembered = true
        savedRegistKey = profile.registKey
        savedRPKey = profile.rpKey
        UserDefaults.standard.set(profile.registKey, forKey: "chiaki_real_regist_key_v102")
        UserDefaults.standard.set(profile.rpKey, forKey: "chiaki_real_rp_key_v102")
        if ps5HostIP.isEmpty { ps5HostIP = profile.host }
    }

    private func upsertProfile(accountBase64: String, registKey: String, rpKey: String, host: String) {
        let numeric = Data(base64Encoded: accountBase64).flatMap { d -> String? in
            guard d.count == 8 else { return nil }
            return String(d.withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) })
        } ?? psnNumericAccountID
        let profile = PS5LinkedProfile(accountBase64: accountBase64, username: psnUsername, numericID: numeric,
                                       registKey: registKey, rpKey: rpKey, host: host, lastConnected: nil)
        if let idx = linkedProfiles.firstIndex(where: { $0.accountBase64 == accountBase64 }) {
            linkedProfiles[idx] = profile
        } else {
            linkedProfiles.append(profile)
        }
        saveProfiles()
        UserDefaults.standard.set(accountBase64, forKey: "ps5_last_profile_v110")
    }

    private func migrateLegacyKeysIntoProfiles() {
        guard !savedRegistKey.isEmpty, !savedRPKey.isEmpty, !psnAccountIDBase64.isEmpty,
              !linkedProfiles.contains(where: { $0.accountBase64 == psnAccountIDBase64 }) else { return }
        upsertProfile(accountBase64: psnAccountIDBase64, registKey: savedRegistKey, rpKey: savedRPKey, host: ps5HostIP)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(linkedProfiles) {
            UserDefaults.standard.set(data, forKey: "ps5_linked_profiles_v110")
        }
        // 1.23: lưu thêm vào Keychain của iPhone -> cập nhật / xoá rồi cài lại app vẫn còn ghép đôi
        PairingVault.save(PairingVault.Snapshot(profiles: linkedProfiles,
                                                lastProfile: UserDefaults.standard.string(forKey: "ps5_last_profile_v110"),
                                                ps5IP: ps5HostIP, ps5Name: discoveredPS5Name))
    }

    private static func loadProfiles() -> [PS5LinkedProfile] {
        var list: [PS5LinkedProfile] = []
        if let data = UserDefaults.standard.data(forKey: "ps5_linked_profiles_v110"),
           let saved = try? JSONDecoder().decode([PS5LinkedProfile].self, from: data) {
            list = saved
        }
        // 1.23: khôi phục từ Keychain (app mới cài lại, UserDefaults trống)
        if let snap = PairingVault.load() {
            for p in snap.profiles where !list.contains(where: { $0.accountBase64 == p.accountBase64 }) {
                list.append(p)
            }
            if UserDefaults.standard.string(forKey: "ps5_last_profile_v110") == nil, let last = snap.lastProfile {
                UserDefaults.standard.set(last, forKey: "ps5_last_profile_v110")
            }
            if UserDefaults.standard.string(forKey: "ps5_ip_v102") == nil, !snap.ps5IP.isEmpty {
                UserDefaults.standard.set(snap.ps5IP, forKey: "ps5_ip_v102")
            }
            if UserDefaults.standard.string(forKey: "ps5_name_v102") == nil, !snap.ps5Name.isEmpty {
                UserDefaults.standard.set(snap.ps5Name, forKey: "ps5_name_v102")
            }
        }
        return list
    }

    // MARK: - 1.23: Mã sao lưu ghép đôi (phòng khi công cụ cài app đổi chữ ký làm mất Keychain)

    /// Chuỗi "PS5T1:..." chứa toàn bộ tài khoản đã ghép đôi. Dán lại vào app để khôi phục, không cần PIN.
    func exportPairingCode() -> String? {
        guard !linkedProfiles.isEmpty else { return nil }
        let snap = PairingVault.Snapshot(profiles: linkedProfiles,
                                         lastProfile: UserDefaults.standard.string(forKey: "ps5_last_profile_v110"),
                                         ps5IP: ps5HostIP, ps5Name: discoveredPS5Name)
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        return "PS5T1:" + data.base64EncodedString()
    }

    /// Trả về số tài khoản khôi phục được (0 = mã sai)
    @discardableResult
    func importPairingCode(_ raw: String) -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = text.range(of: "PS5T1:") else { return 0 }
        let b64 = String(text[r.upperBound...]).components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: b64),
              let snap = try? JSONDecoder().decode(PairingVault.Snapshot.self, from: data) else { return 0 }
        let core = ChiakiEmbeddedCore.shared
        var count = 0
        for p in snap.profiles where core.isValidRegistKey(p.registKey) && core.parseRPKeyBytes(p.rpKey) != nil {
            if let idx = linkedProfiles.firstIndex(where: { $0.accountBase64 == p.accountBase64 }) {
                linkedProfiles[idx] = p
            } else {
                linkedProfiles.append(p)
            }
            count += 1
        }
        guard count > 0 else { return 0 }
        if let last = snap.lastProfile { UserDefaults.standard.set(last, forKey: "ps5_last_profile_v110") }
        if !snap.ps5IP.isEmpty { ps5HostIP = snap.ps5IP }
        if !snap.ps5Name.isEmpty { discoveredPS5Name = snap.ps5Name }
        if let p = preferredProfile() { applyProfileToFields(p) }
        saveProfiles()
        statusLog = "✅ Đã khôi phục \(count) tài khoản đã ghép đôi. Chạm vào tài khoản để kết nối, không cần mã PIN."
        return count
    }

    func disconnectPS5() {
        userRequestedDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        rawRegistTCPConn?.cancel()
        ctrlSessionTCPConn?.cancel()
        udpDiscoveryConn?.cancel()
        remoteSession.stop()
        BackgroundKeepAlive.shared.stop()
        isConnectedToPS5 = false
        isReceivingRealPS5Video = false
        connectionState = .disconnected
        statusLog = "Đã ngắt kết nối PS5."
        updateIdleTimer()
    }

    func startPS5RemoteStreamLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isReceivingRealPS5Video {
                return
            }
            if let standbyImg = self.renderCleanStandbyCanvas() {
                DispatchQueue.main.async {
                    self.currentFullFrame = standbyImg
                }
            }
        }
    }

    private func renderCleanStandbyCanvas() -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.22).setStroke()
            let rect = UIBezierPath(roundedRect: CGRect(x: 60, y: 80, width: 1160, height: 560), cornerRadius: 18)
            rect.lineWidth = 2.0
            rect.stroke()
        }.cgImage
    }
}


// MARK: - 1.23: Kho lưu ghép đôi trong Keychain

/// Khoá ghép đôi Remote Play (RegistKey + RP-Key) do PS5 cấp là VĨNH VIỄN: tắt / bật PS5, đổi mạng,
/// cập nhật app đều không làm mất. Chỉ cần nhập PIN lại khi xoá iPhone khỏi "Thiết bị đã liên kết" trên PS5.
/// Bản cũ chỉ lưu trong UserDefaults -> mất khi xoá app trước khi cài bản mới. Keychain còn lại sau khi xoá app.
enum PairingVault {
    struct Snapshot: Codable {
        var profiles: [PS5LinkedProfile]
        var lastProfile: String?
        var ps5IP: String
        var ps5Name: String
    }

    private static let service = "com.ps5viet.translator.pairing"
    private static let account = "linked_profiles_v1"

    static func save(_ snap: Snapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (k, v) in attrs { add[k] = v }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> Snapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
