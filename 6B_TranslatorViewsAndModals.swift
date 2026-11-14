// ============================================================================
// FILE 6B: 6B_TranslatorViewsAndModals.swift (TÁCH TỪ FILE 6 - PHẦN 2/2)
// PHIÊN BẢN: PS5Translator 1.21 (GIAO DIỆN MỚI: TRANG CHỦ · GAME · THƯ VIỆN GAME, LOG QUÉT CHỮ)
// ============================================================================

import SwiftUI
import WebKit
import UniformTypeIdentifiers

// ============================================================================
// 7. GIAO DIỆN CHÍNH PS5TRANSLATOR
// ============================================================================
struct MainTranslatorView: View {
    @StateObject private var coord = PipelineCoordinator()
    @StateObject private var youtube = YouTubeTranslatorModel()
    @State private var section: MainSection = .home
    @State private var showPS5ConnectSheet = false
    @State private var showSettings = false
    @State private var showLogHistory = false

    var body: some View {
        let fullscreen = coord.isLandscapeFullscreen
        ZStack {
            MQBackground()

            // 1.19: Trang chủ · Game · Thư viện Game (thanh tab dưới), chế độ xoay ngang toàn màn hình giữ như cũ
            VStack(spacing: 0) {
                if !fullscreen && section == .home {
                    homeHeader
                    modeSegmentRow
                }
                if coord.activeTab == .youtube && section == .home {
                    YouTubeTranslatorTab(model: youtube, coord: coord)
                        .ignoresSafeArea(edges: fullscreen ? .all : [])
                } else if fullscreen {
                    PS5FullscreenView(coord: coord, videoMgr: coord.videoMgr)
                } else {
                    switch section {
                    case .home:
                        ps5Home
                    case .game:
                        GamePlayingView(
                            coord: coord,
                            onPlay: {
                                coord.activeTab = .ps5
                                withAnimation { section = .home }
                            },
                            onChangeGame: { withAnimation { section = .library } }
                        )
                    case .library:
                        GameLibraryView(coord: coord, onPicked: { withAnimation { section = .game } })
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !fullscreen {
                    MQTabBar(selection: $section)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .statusBarHidden(fullscreen)
        .onChange(of: coord.isLandscapeFullscreen) { on in
            if on { section = .home }
        }
        .sheet(isPresented: $showPS5ConnectSheet) {
            PS5ConnectionWizardView(coord: coord)
        }
        .sheet(isPresented: $showSettings) {
            MQSettingsSheet(coord: coord, videoMgr: coord.videoMgr, server: coord.server)
        }
        .sheet(isPresented: $showLogHistory) {
            ScanLogHistorySheet(coord: coord)
        }
    }

    // MARK: Thanh đầu: logo MQ · Dịch YouTube · Cài đặt

    private var homeHeader: some View {
        HStack(spacing: 10) {
            MQLogoView(height: 46)
            Spacer(minLength: 6)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    coord.activeTab = coord.activeTab == .youtube ? .ps5 : .youtube
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Dịch YouTube")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .mqPill(coord.activeTab == .youtube)
            }
            .buttonStyle(.plain)

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .mqPill(false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: Remote PS5 · TV · Kết nối PS5 (gộp Liên kết máy PS5 vào đây)

    private var modeSegmentRow: some View {
        HStack(spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { coord.activeTab = .ps5 } }) {
                segLabel("Remote PS5", icon: "gamecontroller.fill")
                    .mqPill(coord.activeTab == .ps5)
            }
            .buttonStyle(.plain)

            MQObserve(coord.server) { server in
                HStack(spacing: 6) {
                    Image(systemName: "tv")
                        .font(.system(size: 14, weight: .semibold))
                    Text("TV: \(server.connectedCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if server.connectedCount > 0 {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                    }
                }
                .foregroundColor(server.connectedCount > 0 ? .white : MQTheme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
            }

            MQObserve(coord.videoMgr) { videoMgr in
                Button(action: { showPS5ConnectSheet = true }) {
                    segLabel(videoMgr.isConnectedToPS5 ? "Đổi PS5" : "Kết nối PS5", icon: "link")
                        .foregroundColor(.white)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(MQTheme.hairline, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func segLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
    }

    // MARK: Nội dung Trang chủ (Remote PS5)

    private var ps5Home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                statusRow
                ps5ScreenViewport
                ScanLogPanel(coord: coord, onShowAll: { showLogHistory = true })
                controlsCard
            }
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    private var statusRow: some View {
        MQObserve(coord.videoMgr) { _ in statusRowContent }
    }

    private var statusRowContent: some View {
        Button(action: { showPS5ConnectSheet = true }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(coord.videoMgr.isConnectedToPS5 ? Color.green : (coord.videoMgr.isAccountRemembered ? Color.white : Color.orange))
                    .frame(width: 9, height: 9)
                    .shadow(color: (coord.videoMgr.isConnectedToPS5 ? Color.green : Color.white).opacity(0.7), radius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TranslatorV102Config.appVersionName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(statusSubtitle)
                        .font(.system(size: 13))
                        .foregroundColor(MQTheme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(MQTheme.secondary)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusSubtitle: String {
        let ps5: String
        if coord.videoMgr.isConnectedToPS5 {
            ps5 = "Chiaki Live: \(coord.videoMgr.ps5HostIP)"
        } else if coord.videoMgr.isAccountRemembered {
            ps5 = "Đã nhớ TK: \(coord.videoMgr.psnUsername)"
        } else {
            ps5 = "Chưa nối PS5"
        }
        return "\(ps5) · Đang chơi: \(coord.activeProfileFolderName)"
    }

    private var ps5ScreenViewport: some View {
        MQObserve(coord.videoMgr) { videoMgr in
            viewportContent(videoMgr)
        }
    }

    private func viewportContent(_ videoMgr: VideoSourceManager) -> some View {
        ZStack {
            if let img = videoMgr.currentFullFrame {
                Image(uiImage: UIImage(cgImage: img))
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        GeometryReader { geo in
                            ZStack {
                                // Khung dịch neo đúng vị trí chữ gốc, cùng cỡ chữ / màu chữ / màu nền
                                ForEach(coord.translatedBoxes) { box in
                                    TranslatedSubtitleBoxView(box: box, frameSize: geo.size)
                                }
                            }
                        }
                    )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 30, weight: .light))
                    Text("Quét màn hình để dịch")
                        .font(.system(size: 17, weight: .semibold))
                    Text(videoMgr.isConnectedToPS5 ? "Đang chờ luồng hình từ PS5..." : "(Màn hình PS5 được truyền về iPhone)")
                        .font(.system(size: 12))
                        .foregroundColor(MQTheme.tertiary)
                }
                .foregroundColor(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                        .foregroundColor(Color.white.opacity(0.22))
                        .padding(8)
                )
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .overlay(
            Button(action: { coord.isLandscapeFullscreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.ultraThinMaterial))
                    .foregroundColor(.white)
            }
            .padding(10),
            alignment: .topTrailing
        )
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
        .padding(.horizontal, 14)
    }

    // MARK: Tốc độ quét · Dịch AI (đã bỏ "Vùng quét chữ": app luôn dịch toàn màn hình)

    private var controlsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text("Tốc độ quét: \(Int(coord.scanFPS)) FPS")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize()
                Slider(
                    value: $coord.scanFPS,
                    in: TranslatorV102Config.minScanFPS...TranslatorV102Config.maxScanFPS,
                    step: 1.0
                )
                .tint(.white)
            }
            .frame(height: 50)

            Rectangle().fill(MQTheme.hairline).frame(height: 1)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dịch AI: Tất cả (khuyên dùng)")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Câu chưa có trong data Việt hoá: Apple AI dịch trước, không được thì Google.")
                        .font(.system(size: 12))
                        .foregroundColor(MQTheme.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: $coord.enableAppleIntelligenceFallback)
                    .labelsHidden()
                    .tint(MQTheme.toggleOn)
            }
            .padding(.vertical, 10)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .mqGlass(24)
        .padding(.horizontal, 14)
    }
}

// ============================================================================
// 8. MÀN HÌNH QUẢN LÝ HỒ SƠ GAME
// ============================================================================
struct GameProfileFolderManagerView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode

    @State private var newProfileName: String = ""
    @State private var selectedFolderForImport: String = ""
    @State private var showFileImporter: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. Hồ sơ Game đang kích hoạt")) {
                    HStack {
                        Image(systemName: "folder.fill.badge.checkmark")
                            .foregroundColor(.cyan)
                        Text("Thư mục đang dùng:")
                        Spacer()
                        Text("\(coord.activeProfileFolderName) (\(coord.loadedLineCount) câu)")
                            .bold()
                            .foregroundColor(.cyan)
                    }
                    // 1.11: kết quả kiểm tra data Việt hoá
                    Text(coord.databaseReport)
                        .font(.caption)
                        .foregroundColor(coord.loadedLineCount == 0 ? .orange : .green)

                    Button(action: {
                        coord.triggerTVTestSentence()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Label("Gửi câu Test \"\(TranslatorV102Config.tvTestSentence)\" lên TV", systemImage: "tv.badge.wifi")
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                    }
                }

                Section(header: Text("2. Tạo thư mục Hồ sơ Game mới")) {
                    TextField("Nhập tên Hồ sơ Game (VD: Until Dawn, God of War)", text: $newProfileName)

                    HStack(spacing: 12) {
                        Button(action: {
                            guard !newProfileName.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else { return }
                            coord.createNewGameProfileFolder(folderName: newProfileName)
                            newProfileName = ""
                        }) {
                            Label("Chỉ tạo thư mục", systemImage: "folder.badge.plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            let target = newProfileName.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty ? "Game Mới" : newProfileName
                            coord.createNewGameProfileFolder(folderName: target)
                            selectedFolderForImport = target
                            newProfileName = ""
                            showFileImporter = true
                        }) {
                            Label("Tạo thư mục & Chọn file .sqlite", systemImage: "doc.badge.plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section(header: Text("3. Danh sách Thư mục Hồ sơ Game (/GameProfiles/)")) {
                    if coord.gameProfiles.isEmpty {
                        Text("Chưa có thư mục hồ sơ nào. Hãy tạo hồ sơ mới ở mục 2.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        ForEach(coord.gameProfiles) { profile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(coord.activeProfileFolderName == profile.folderName ? .green : .cyan)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.folderName)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("Thư mục: /GameProfiles/\(profile.folderName)/\(profile.sqliteFileName)")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if coord.activeProfileFolderName == profile.folderName {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }

                                HStack(spacing: 10) {
                                    Button(action: {
                                        coord.activateGameProfileFolder(folderName: profile.folderName)
                                    }) {
                                        Text(coord.activeProfileFolderName == profile.folderName ? "Đang sử dụng" : "Kích hoạt hồ sơ này")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(coord.activeProfileFolderName == profile.folderName ? Color.green.opacity(0.25) : Color.blue.opacity(0.3))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        selectedFolderForImport = profile.folderName
                                        showFileImporter = true
                                    }) {
                                        Label("Nạp file .sqlite riêng", systemImage: "arrow.down.doc.fill")
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.white.opacity(0.12))
                                            .foregroundColor(.cyan)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Button(action: {
                                        coord.deleteGameProfileFolder(folderName: profile.folderName)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: Text("4. Thông tin Kết nối TV Samsung & AI")) {
                    HStack {
                        Text("Địa chỉ IP iPhone (Nhập vào TV):")
                        Spacer()
                        Text("\(coord.server.ipAddress):\(AppConfig.webSocketPort)")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Số TV Samsung đang kết nối:")
                        Spacer()
                        Text("\(coord.server.connectedCount) TV")
                            .bold()
                    }
                    Toggle("Dịch AI online cho câu chưa có trong data", isOn: $coord.enableAppleIntelligenceFallback)
                }
            }
            .navigationTitle("Quản lý Hồ sơ Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let selectedURL = urls.first {
                    let targetFolder = selectedFolderForImport.isEmpty ? coord.activeProfileFolderName : selectedFolderForImport
                    coord.importSQLiteIntoProfileFolder(folderName: targetFolder, sourceURL: selectedURL)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ============================================================================
// 9. MÀN HÌNH LIÊN KẾT CHIAKI PS5 & GHI NHỚ TÀI KHOẢN VĨNH VIỄN
// ============================================================================
struct PS5ConnectionWizardView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var showPSNWebLogin = false

    var body: some View {
        // 1.21: giao diện đen mờ & trắng, bo tròn (đồng bộ với app)
        MQObserve(coord.videoMgr) { videoMgr in
            content(videoMgr)
        }
    }

    private func content(_ videoMgr: VideoSourceManager) -> some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Trạng thái lõi Chiaki
                    HStack(spacing: 14) {
                        Image(systemName: videoMgr.isConnectedToPS5 ? "checkmark.seal.fill" : "gamecontroller.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(videoMgr.isConnectedToPS5 ? MQTheme.ink : .white)
                            .frame(width: 56, height: 56)
                            .background(
                                Circle().fill(videoMgr.isConnectedToPS5 ? MQTheme.pearl : Color.white.opacity(0.10))
                            )
                            .overlay(Circle().stroke(MQTheme.hairline, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lõi Chiaki-NG PS5 Remote Play")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text(videoMgr.statusLog)
                                .font(.system(size: 13))
                                .foregroundColor(videoMgr.statusLog.contains("❌") || videoMgr.statusLog.contains("⚠️") ? .orange : MQTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .mqGlass(24)

                    // BƯỚC 1: IP PS5
                    stepCard(1, "Địa chỉ IP của máy PS5") {
                        HStack(spacing: 8) {
                            TextField("VD: 192.168.2.23", text: $coord.videoMgr.ps5HostIP)
                                .keyboardType(.numbersAndPunctuation)
                                .font(.system(size: 17, weight: .medium))
                                .modifier(MQField())
                            Button(action: { videoMgr.scanForPS5OnLAN() }) {
                                Label("Quét tìm", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 46)
                                    .mqPill(true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // BƯỚC 2: TÀI KHOẢN PSN
                    stepCard(2, "Tài khoản PSN", trailing: videoMgr.isAccountRemembered ? "Đã ghi nhớ" : nil) {
                        Text("Màn hình lấy mã PIN 8 số trên PS5 đang mở ở User nào thì nhập đúng tài khoản PSN của User đó.")
                            .font(.system(size: 12))
                            .foregroundColor(MQTheme.tertiary)

                        HStack(spacing: 8) {
                            TextField("Online ID PSN (VD: Maivy1125)", text: $coord.videoMgr.psnUsername)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 17, weight: .medium))
                                .modifier(MQField())
                            Button(action: { videoMgr.lookupAccountIDByPSNUsername() }) {
                                Label("Tự lấy ID", systemImage: "magnifyingglass")
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 46)
                                    .mqPill(false)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 8) {
                            TextField("Account ID Base64 (hoặc số ID 19 chữ số)", text: $coord.videoMgr.psnAccountIDBase64)
                                .font(.system(size: 14, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .modifier(MQField())
                            Button(action: { showPSNWebLogin = true }) {
                                Label("Đăng nhập Sony", systemImage: "person.badge.key.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 46)
                                    .mqPill(true)
                            }
                            .buttonStyle(.plain)
                        }

                        if videoMgr.isAccountRemembered {
                            HStack(alignment: .top) {
                                Text("Online ID: \(videoMgr.psnUsername) · Số ID: \(videoMgr.psnNumericAccountID)")
                                    .font(.system(size: 12))
                                    .foregroundColor(MQTheme.secondary)
                                Spacer()
                                Button("Xoá & đổi TK") { videoMgr.clearRememberedAccount() }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    // Tài khoản đã liên kết + tự kết nối lại
                    LinkedPS5ProfilesSection(videoMgr: coord.videoMgr)

                    // BƯỚC 3: PIN 8 SỐ
                    stepCard(3, "Mã PIN 8 số (chỉ cần lần đầu)") {
                        Text("Trên PS5 (đúng tài khoản PSN vừa chọn): Cài đặt → Hệ thống → Chơi từ xa → Liên kết thiết bị.")
                            .font(.system(size: 12))
                            .foregroundColor(MQTheme.tertiary)
                        TextField("4326 2954", text: $coord.videoMgr.psnPinCode)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .modifier(MQField(height: 58))
                    }

                    Button(action: {
                        videoMgr.pairAndConnectToPS5(
                            username: videoMgr.psnUsername,
                            accountIDBase64: videoMgr.psnAccountIDBase64,
                            pinCode: videoMgr.psnPinCode,
                            ip: videoMgr.ps5HostIP
                        )
                    }) {
                        Label("Liên kết & ghi nhớ tài khoản", systemImage: "link")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .mqPill(true)
                    }
                    .buttonStyle(.plain)

                    if videoMgr.isConnectedToPS5 {
                        Button(action: { videoMgr.disconnectPS5() }) {
                            Text("Ngắt kết nối PS5 hiện tại")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Capsule().fill(Color.red.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(MQBackground())
            .navigationTitle("Kết nối PS5")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showPSNWebLogin) {
                PSNWebLoginHelperView(coord: coord)
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private func stepCard<Content: View>(_ n: Int, _ title: String, trailing: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(n)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(MQTheme.ink)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(MQTheme.pearl))
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if let t = trailing {
                    Label(t, systemImage: "checkmark.shield.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(MQTheme.secondary)
                }
            }
            content()
        }
        .padding(14)
        .mqGlass(24)
    }
}

/// 1.21: ô nhập liệu bo tròn kiểu đen mờ
struct MQField: ViewModifier {
    var height: CGFloat = 46
    func body(content: Content) -> some View {
        content
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MQTheme.hairline, lineWidth: 1))
    }
}

// ============================================================================
// 10. TRÌNH ĐĂNG NHẬP SONY OAUTH & BỘ QUÉT ĐỆ QUY ĐA TẦNG (ĐỒNG BỘ COOKIE DEFAULT)
// ============================================================================
struct PSNWebLoginHelperView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var extractionStatus: String = "Đăng nhập đúng tài khoản PSN đang mở trên máy PS5. App sẽ tự lấy Account ID 8-byte và ghi nhớ vĩnh viễn."
    @State private var manualCheckTrigger: Int = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(extractionStatus)
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    Button(action: {
                        extractionStatus = "Đang quét Cookie npsso & lấy Account ID 8-byte..."
                        manualCheckTrigger += 1
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.shield.fill")
                            Text("Lấy ID ngay")
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.25))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                SonyOAuthWebView(
                    url: URL(string: TranslatorV102Config.sonyOAuthLoginURL)!,
                    manualCheckTrigger: manualCheckTrigger,
                    onExtractedAccount: { onlineID, base64ID, numericID in
                        let finalUser = onlineID.isEmpty ? coord.videoMgr.psnUsername : onlineID
                        coord.videoMgr.saveRememberedAccount(
                            username: finalUser,
                            accountIDBase64: base64ID,
                            numericID: numericID
                        )
                        self.extractionStatus = "✅ Đã lấy thành công Account ID 8-byte (\(base64ID)) • Số ID: \(numericID)!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    },
                    onStatusUpdate: { msg in
                        self.extractionStatus = msg
                    }
                )
            }
            .navigationTitle("Đăng nhập Sony (Tự lấy 8-byte)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SonyOAuthWebView: UIViewRepresentable {
    let url: URL
    let manualCheckTrigger: Int
    let onExtractedAccount: (String, String, String) -> Void
    let onStatusUpdate: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExtractedAccount: onExtractedAccount, onStatusUpdate: onStatusUpdate)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attachedWebView = webView
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastManualTrigger != manualCheckTrigger {
            context.coordinator.lastManualTrigger = manualCheckTrigger
            context.coordinator.inspectCookiesAndDOMForAccountID(in: uiView, forceSilentAuth: true)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onExtractedAccount: (String, String, String) -> Void
        let onStatusUpdate: (String) -> Void
        weak var attachedWebView: WKWebView?
        var lastManualTrigger: Int = 0
        private var didExtractSuccess = false
        private var didExchangeCode = false
        private var isTryingSilentCookieAuth = false

        init(onExtractedAccount: @escaping (String, String, String) -> Void, onStatusUpdate: @escaping (String) -> Void) {
            self.onExtractedAccount = onExtractedAccount
            self.onStatusUpdate = onStatusUpdate
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let reqURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let currentURL = reqURL.absoluteString

            if handlePotentialRedirectURL(currentURL) {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if let failingURL = nsErr.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                _ = handlePotentialRedirectURL(failingURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didExtractSuccess else { return }
            inspectCookiesAndDOMForAccountID(in: webView, forceSilentAuth: false)
        }

        private func handlePotentialRedirectURL(_ urlString: String) -> Bool {
            guard urlString.hasPrefix(TranslatorV102Config.sonyOAuthRedirectPrefix) ||
                  urlString.contains("scecompcall://redirect") ||
                  urlString.contains("remoteplay/redirect") ||
                  urlString.contains("code=v3.") else {
                return false
            }

            if let components = URLComponents(string: urlString),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
               !code.isEmpty,
               !didExchangeCode {
                didExchangeCode = true
                DispatchQueue.main.async {
                    self.onStatusUpdate("Đã nhận mã OAuth từ Sony! Đang giải mã JWT & lấy Account ID 8-byte...")
                }
                exchangeOAuthCodeForAccountID(code: code)
            }
            return true
        }

        func inspectCookiesAndDOMForAccountID(in webView: WKWebView, forceSilentAuth: Bool) {
            guard !didExtractSuccess else { return }

            let jsFetchProfile = """
            (async function() {
                try {
                    const r1 = await fetch('https://web.np.playstation.com/api/basicProfile/v1/profile/users/me', { credentials: 'include' });
                    if (r1.ok) {
                        const j1 = await r1.json();
                        return JSON.stringify(j1);
                    }
                } catch (e) {}
                return "";
            })();
            """

            webView.evaluateJavaScript(jsFetchProfile) { [weak self] result, _ in
                guard let self = self, !self.didExtractSuccess else { return }
                if let jsonStr = result as? String,
                   !jsonStr.isEmpty,
                   let data = jsonStr.data(using: .utf8),
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(onlineID: found.onlineID, base64ID: found.base64ID, numericID: found.numericID)
                }
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.didExtractSuccess else { return }
                let sonyCookies = cookies.filter {
                    $0.domain.contains("sony.com") || $0.domain.contains("playstation.net") || $0.domain.contains("playstation.com")
                }
                guard !sonyCookies.isEmpty else { return }

                for cookie in sonyCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }

                let hasNpsso = sonyCookies.contains { $0.name.lowercased() == "npsso" && $0.value.count >= 24 }
                let currentHost = webView.url?.host?.lowercased() ?? ""
                let isPostLoginPage = currentHost.contains("my.account.sony.com") ||
                                      currentHost.contains("playstation.com") ||
                                      forceSilentAuth

                if (hasNpsso || isPostLoginPage) && !self.didExchangeCode && !self.isTryingSilentCookieAuth {
                    self.isTryingSilentCookieAuth = true
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Đã phát hiện phiên đăng nhập Sony! Đang trích xuất mã Account ID 8-byte...")
                    }
                    self.performSilentAuthorizeWithCookies(sonyCookies)
                }
            }
        }

        private func performSilentAuthorizeWithCookies(_ cookies: [HTTPCookie]) {
            let silentURLStr = TranslatorV102Config.sonyOAuthLoginURL + "&prompt=none"
            guard let silentURL = URL(string: silentURLStr) else {
                isTryingSilentCookieAuth = false
                return
            }

            let config = URLSessionConfiguration.default
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .always

            let catcher = SilentOAuthRedirectCatcher { [weak self] code in
                guard let self = self else { return }
                self.isTryingSilentCookieAuth = false
                if let code = code, !code.isEmpty, !self.didExchangeCode {
                    self.didExchangeCode = true
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Đã lấy mã uỷ quyền từ Cookie Sony! Đang giải mã Account ID 8-byte...")
                    }
                    self.exchangeOAuthCodeForAccountID(code: code)
                }
            }

            let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)
            var req = URLRequest(url: silentURL)
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            session.dataTask(with: req).resume()
        }

        private func exchangeOAuthCodeForAccountID(code: String) {
            guard let tokenURL = URL(string: TranslatorV102Config.sonyOAuthTokenURL) else { return }
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(TranslatorV102Config.sonyBasicAuthHeader, forHTTPHeaderField: "Authorization")

            let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
            let bodyStr = "grant_type=authorization_code&code=\(encodedCode)&redirect_uri=\(TranslatorV102Config.sonyOAuthRedirectEncoded)&token_format=jwt"
            req.httpBody = bodyStr.data(using: .utf8)

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.didExchangeCode = false
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Không đổi được token từ Sony. Hãy bấm 'Lấy ID ngay' hoặc đăng nhập lại.")
                    }
                    return
                }

                if let directFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(
                        onlineID: directFound.onlineID,
                        base64ID: directFound.base64ID,
                        numericID: directFound.numericID
                    )
                    return
                }

                guard let accessToken = json["access_token"] as? String else {
                    self.didExchangeCode = false
                    return
                }

                if let jwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(accessToken) {
                    self.completeExtraction(
                        onlineID: jwtFound.onlineID,
                        base64ID: jwtFound.base64ID,
                        numericID: jwtFound.numericID
                    )
                    return
                }

                if let idToken = json["id_token"] as? String,
                   let idJwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(idToken) {
                    self.completeExtraction(
                        onlineID: idJwtFound.onlineID,
                        base64ID: idJwtFound.base64ID,
                        numericID: idJwtFound.numericID
                    )
                    return
                }

                self.fetchPSNAccountID(accessToken: accessToken)
            }.resume()
        }

        private func fetchPSNAccountID(accessToken: String) {
            let endpoints: [(url: String, useBasicAuth: Bool)] = [
                ("https://dms.api.playstation.com/api/v1/devices/accounts/me", false),
                ("https://ca.account.sony.com/api/v1/oauth/token/\(accessToken)", true),
                ("https://us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=npId,onlineId,accountId,avatarUrls,plus", false),
                ("https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles", false),
                ("https://web.np.playstation.com/api/basicProfile/v1/profile/users/me", false)
            ]

            tryEndpoint(at: 0, endpoints: endpoints, accessToken: accessToken)
        }

        private func tryEndpoint(at index: Int, endpoints: [(url: String, useBasicAuth: Bool)], accessToken: String) {
            guard !didExtractSuccess else { return }
            guard index < endpoints.count else {
                self.didExchangeCode = false
                DispatchQueue.main.async {
                    self.onStatusUpdate("⚠️ Chưa trích xuất được Account ID tự động. Hãy bấm nút 'Lấy ID ngay' ở góc phải.")
                }
                return
            }

            let item = endpoints[index]
            guard let url = URL(string: item.url) else {
                tryEndpoint(at: index + 1, endpoints: endpoints, accessToken: accessToken)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 6.0
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if item.useBasicAuth {
                req.setValue(TranslatorV102Config.sonyBasicAuthHeader, forHTTPHeaderField: "Authorization")
            } else {
                req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self, !self.didExtractSuccess else { return }
                if let data = data,
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(
                        onlineID: found.onlineID,
                        base64ID: found.base64ID,
                        numericID: found.numericID
                    )
                    return
                }
                self.tryEndpoint(at: index + 1, endpoints: endpoints, accessToken: accessToken)
            }.resume()
        }

        private func completeExtraction(onlineID: String, base64ID: String, numericID: String) {
            guard !didExtractSuccess else { return }
            didExtractSuccess = true
            DispatchQueue.main.async {
                self.onExtractedAccount(onlineID, base64ID, numericID)
            }
        }
    }
}

// 1.14: Vẽ 1 khung dịch: chữ ĐẬM, nền ĐEN, cỡ chữ CỐ ĐỊNH (không tự thu nhỏ).
// Khung nằm trong vùng đã tính sẵn: thoại neo ĐÁY + căn giữa, menu/lựa chọn neo GÓC TRÁI-TRÊN.
// Nếu chữ dài hơn dự tính thì khung tự giãn thêm dòng thay vì thu nhỏ chữ.
struct TranslatedSubtitleBoxView: View {
    let box: TranslatedBox
    let frameSize: CGSize

    var body: some View {
        let W = frameSize.width, H = frameSize.height
        let fontSize: CGFloat = box.fontSizeNorm > 0
            ? CGFloat(box.fontSizeNorm) * H
            : max(9.5, min(18.0, CGFloat(box.h) * H * 0.78))
        let center = box.textAlignCenter
        let padX = fontSize * (center ? 0.35 : 0.32)
        let padY = fontSize * (center ? 0.18 : 0.14)
        let textColor = Color(hexString: box.textColorHex) ?? .white
        let boxW = CGFloat(box.w) * W
        let boxH = CGFloat(box.h) * H

        Color.clear
            .frame(width: boxW, height: boxH)
            .overlay(
                Text(box.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(center ? .center : .leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(10, boxW - padX * 2), alignment: center ? .center : .leading)
                    .padding(.horizontal, padX)
                    .padding(.vertical, padY)
                    .background(
                        RoundedRectangle(cornerRadius: max(3, fontSize * 0.22))
                            .fill(Color.black.opacity(0.86))
                    ),
                alignment: center ? .bottom : .topLeading
            )
            .position(x: CGFloat(box.x) * W + boxW / 2, y: CGFloat(box.y) * H + boxH / 2)
            .animation(nil, value: box)
            .allowsHitTesting(false)
    }
}

extension Color {
    /// "#RRGGBB" -> Color
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// 1.10: Danh sách tài khoản PS5 đã liên kết + tuỳ chọn tự kết nối lại / chạy nền
struct LinkedPS5ProfilesSection: View {
    @ObservedObject var videoMgr: VideoSourceManager
    /// 1.23: thông báo sao lưu / khôi phục mã ghép đôi
    @State private var backupMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(MQTheme.ink)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(MQTheme.pearl))
                Text("Tài khoản đã liên kết")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("Chạm để kết nối, không cần PIN.")
                .font(.system(size: 12))
                .foregroundColor(MQTheme.tertiary)

            if videoMgr.linkedProfiles.isEmpty {
                Text("Chưa có tài khoản nào. Ghép đôi bằng mã PIN 8 số ở bước 3 (mỗi tài khoản PSN ghép 1 lần).")
                    .font(.system(size: 13))
                    .foregroundColor(MQTheme.secondary)
            } else {
                ForEach(videoMgr.linkedProfiles) { profile in
                    let isCurrent = profile.accountBase64 == videoMgr.psnAccountIDBase64
                    HStack(spacing: 10) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "person.crop.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.username.isEmpty ? profile.accountBase64 : profile.username)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("PS5: \(profile.host)")
                                .font(.system(size: 12))
                                .foregroundColor(MQTheme.tertiary)
                        }
                        Spacer()
                        Button(action: { videoMgr.connectWithProfile(profile) }) {
                            Text("Kết nối")
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .mqPill(true)
                        }
                        .buttonStyle(.plain)
                        Button(action: { videoMgr.removeProfile(profile) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.red.opacity(0.85))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MQTheme.rowFill))
                }
            }

            // 1.23: sao lưu / khôi phục ghép đôi (dán lại sau khi cài app mới, không cần nhập PIN)
            Text("Ghép đôi được lưu vĩnh viễn trong iPhone (cả khi cập nhật hay xoá rồi cài lại app). Tắt / bật PS5 không cần nhập lại PIN. Nên bấm Sao lưu và dán mã vào Ghi chú để phòng hờ.")
                .font(.system(size: 12))
                .foregroundColor(MQTheme.tertiary)
            HStack(spacing: 10) {
                Button(action: {
                    if let code = videoMgr.exportPairingCode() {
                        UIPasteboard.general.string = code
                        backupMessage = "✅ Đã chép mã sao lưu (\(videoMgr.linkedProfiles.count) tài khoản). Dán vào Ghi chú để giữ."
                    } else {
                        backupMessage = "Chưa có tài khoản nào để sao lưu."
                    }
                }) {
                    Label("Sao lưu", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .mqPill(false)
                }
                .buttonStyle(.plain)
                Button(action: {
                    let n = videoMgr.importPairingCode(UIPasteboard.general.string ?? "")
                    backupMessage = n > 0
                        ? "✅ Đã khôi phục \(n) tài khoản. Chạm Kết nối, không cần PIN."
                        : "Không thấy mã sao lưu. Hãy chép mã bắt đầu bằng PS5T1: rồi bấm lại."
                }) {
                    Label("Khôi phục", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .mqPill(false)
                }
                .buttonStyle(.plain)
            }
            if !backupMessage.isEmpty {
                Text(backupMessage)
                    .font(.system(size: 12))
                    .foregroundColor(MQTheme.secondary)
            }

            Rectangle().fill(MQTheme.hairline).frame(height: 1)

            Toggle(isOn: $videoMgr.autoReconnectEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tự kết nối lại").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text("Khi mở app, khi quay lại app, hoặc khi PS5 ngắt phiên (đổi tài khoản bằng nút PS)")
                        .font(.system(size: 12)).foregroundColor(MQTheme.tertiary)
                }
            }
            .tint(MQTheme.toggleOn)
            Toggle(isOn: $videoMgr.keepAliveInBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Giữ kết nối khi thoát app ra ngoài").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text("App tiếp tục chạy nền để không mất Remote Play (tốn pin hơn)")
                        .font(.system(size: 12)).foregroundColor(MQTheme.tertiary)
                }
            }
            .tint(MQTheme.toggleOn)
            Toggle(isOn: $videoMgr.preventAutoLock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Không tự khoá màn hình").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text("Màn hình luôn sáng khi đang kết nối PS5. Lỡ khoá máy: mở lại app sẽ tự kết nối lại.")
                        .font(.system(size: 12)).foregroundColor(MQTheme.tertiary)
                }
            }
            .tint(MQTheme.toggleOn)
        }
        .padding(14)
        .mqGlass(24)
    }
}

@main
struct PS5TranslatorApp: App {
    // 1.12: điều khiển xoay ngang toàn màn hình
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) var orientationDelegate

    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}
