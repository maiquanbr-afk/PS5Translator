// ============================================================================
// FILE 2C: 2C_ChiakiRemotePlaySession.swift
// PHIÊN BẢN: PS5Translator 1.10 (LÕI CHIAKI-NG ĐẦY ĐỦ: NHẬN HÌNH PS5 THẬT)
//
// - PS5RemotePlaySession: bọc thư viện C chiaki-ng (libps5native.a) qua
//   PS5RemotePlayBridge.h. Toàn bộ sess/init, sess/ctrl, Takion, ECDH, giải mã
//   gkcrypt, FEC, ghép khung hình do chiaki-ng xử lý (giống app Chiaki trên PC).
// - AnnexBH264Decoder: giải mã khung hình H.264 Annex-B bằng VideoToolbox (phần cứng)
//   rồi xuất CGImage cho OCR và màn hình xem trước.
// - BackgroundKeepAlive: giữ app chạy nền (âm thanh im lặng) để không rớt Remote Play
//   khi thoát app ra ngoài.
// ============================================================================

import Foundation
import CoreGraphics
import CoreMedia
import VideoToolbox
import AVFoundation
import UIKit

// MARK: - Phiên Remote Play chiaki-ng

final class PS5RemotePlaySession {
    enum Event {
        case connected
        case quit(code: Int32, message: String)
        case log(level: Int32, message: String)
        case loginPinRequested(incorrect: Bool)
        case nickname(String)
    }

    var onEvent: ((Event) -> Void)?
    var onFrame: ((CGImage) -> Void)?

    private var handle: OpaquePointer?
    private let decoder = AnnexBH264Decoder()
    private let stateLock = NSLock()
    private(set) var isRunning = false

    init() {
        decoder.onFrame = { [weak self] img in self?.onFrame?(img) }
        decoder.onNeedKeyframe = { [weak self] in self?.requestKeyframe() }
    }

    /// Bắt đầu phiên. registKey16 / morning16 phải đúng 16 byte, accountID8 = 8 byte.
    func start(host: String, registKey16: [UInt8], morning16: [UInt8], accountID8: [UInt8]?,
               width: UInt32 = 1280, height: UInt32 = 720, fps: UInt32 = 30, bitrate: UInt32 = 10000) -> Int32 {
        guard registKey16.count == 16, morning16.count == 16 else { return -1 }
        stop()
        decoder.reset()

        let user = Unmanaged.passUnretained(self).toOpaque()
        var err: Int32 = 0
        let accountPtr: [UInt8]? = (accountID8?.count == 8) ? accountID8 : nil

        let h: OpaquePointer? = host.withCString { hostC in
            registKey16.withUnsafeBufferPointer { rk in
                morning16.withUnsafeBufferPointer { mk -> OpaquePointer? in
                    if let acc = accountPtr {
                        return acc.withUnsafeBufferPointer { ap -> OpaquePointer? in
                            ps5rp_start(hostC, rk.baseAddress, mk.baseAddress, ap.baseAddress,
                                        width, height, fps, bitrate, 0,
                                        ps5rpVideoTrampoline, ps5rpEventTrampoline, user, &err)
                        }
                    }
                    return ps5rp_start(hostC, rk.baseAddress, mk.baseAddress, nil,
                                       width, height, fps, bitrate, 0,
                                       ps5rpVideoTrampoline, ps5rpEventTrampoline, user, &err)
                }
            }
        }

        stateLock.lock()
        handle = h
        isRunning = (h != nil)
        stateLock.unlock()
        return h == nil ? (err == 0 ? -2 : err) : 0
    }

    /// Dừng phiên (an toàn khi gọi từ bất kỳ luồng nào, kể cả trong callback).
    func stop(completion: (() -> Void)? = nil) {
        stateLock.lock()
        let h = handle
        handle = nil
        isRunning = false
        stateLock.unlock()

        guard let h = h else {
            completion?()
            return
        }
        // ps5rp_stop_and_free chờ luồng chiaki kết thúc -> chạy trên luồng nền.
        // Giữ self sống tới khi C không còn gọi callback.
        DispatchQueue.global(qos: .userInitiated).async {
            ps5rp_stop_and_free(h)
            _ = self
            completion?()
        }
    }

    func requestKeyframe() {
        stateLock.lock()
        let h = handle
        stateLock.unlock()
        if let h = h { _ = ps5rp_request_idr(h) }
    }

    func setController(buttons: UInt32, l2: UInt8 = 0, r2: UInt8 = 0,
                       leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        stateLock.lock()
        let h = handle
        stateLock.unlock()
        if let h = h { _ = ps5rp_set_controller(h, buttons, l2, r2, leftX, leftY, rightX, rightY) }
    }

    // Gọi từ trampoline C
    fileprivate func handleVideo(_ data: Data, framesLost: Int32) {
        decoder.decode(annexBFrame: data, framesLost: framesLost)
    }

    fileprivate func handleEvent(kind: Int32, code: Int32, message: String) {
        switch kind {
        case PS5RP_EVENT_CONNECTED:
            onEvent?(.connected)
        case PS5RP_EVENT_QUIT:
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            onEvent?(.quit(code: code, message: message))
        case PS5RP_EVENT_LOG:
            onEvent?(.log(level: code, message: message))
        case PS5RP_EVENT_LOGIN_PIN_REQUEST:
            onEvent?(.loginPinRequested(incorrect: code != 0))
        case PS5RP_EVENT_NICKNAME:
            onEvent?(.nickname(message))
        default:
            break
        }
    }
}

private func ps5rpVideoTrampoline(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ framesLost: Int32, _ user: UnsafeMutableRawPointer?) {
    guard let buf = buf, len > 0, let user = user else { return }
    let session = Unmanaged<PS5RemotePlaySession>.fromOpaque(user).takeUnretainedValue()
    session.handleVideo(Data(bytes: buf, count: len), framesLost: framesLost)
}

private func ps5rpEventTrampoline(_ kind: Int32, _ code: Int32, _ msg: UnsafePointer<CChar>?, _ user: UnsafeMutableRawPointer?) {
    guard let user = user else { return }
    let session = Unmanaged<PS5RemotePlaySession>.fromOpaque(user).takeUnretainedValue()
    let message = msg.map { String(cString: $0) } ?? ""
    session.handleEvent(kind: kind, code: code, message: message)
}

// MARK: - Giải mã H.264 Annex-B bằng VideoToolbox

final class AnnexBH264Decoder {
    var onFrame: ((CGImage) -> Void)?
    var onNeedKeyframe: (() -> Void)?
    /// Số khung hình/giây tối đa chuyển sang CGImage (OCR chỉ cần 6-15 FPS)
    var maxOutputFPS: Double = 15

    private let queue = DispatchQueue(label: "ps5translator.h264decoder")
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyframe = true
    private var lastOutputTime: CFTimeInterval = 0
    private var lastIDRRequest: CFTimeInterval = 0

    func reset() {
        queue.async {
            self.invalidateSession()
            self.sps = nil
            self.pps = nil
            self.waitingForKeyframe = true
        }
    }

    func decode(annexBFrame: Data, framesLost: Int32) {
        queue.async { self.decodeOnQueue(annexBFrame) }
    }

    private func decodeOnQueue(_ frame: Data) {
        let nals = Self.splitAnnexB(frame)
        guard !nals.isEmpty else { return }

        var newSPS: Data?
        var newPPS: Data?
        var sliceNALs: [Data] = []
        var hasIDR = false

        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: newSPS = nal
            case 8: newPPS = nal
            case 5: hasIDR = true; sliceNALs.append(nal)
            case 1, 2, 3, 4: sliceNALs.append(nal)
            default: break // SEI, AUD... bỏ qua
            }
        }

        if let s = newSPS, let p = newPPS, (s != sps || p != pps || session == nil) {
            sps = s
            pps = p
            createSession()
        }

        guard let session = session, let desc = formatDesc, !sliceNALs.isEmpty else { return }
        if waitingForKeyframe && !hasIDR {
            requestKeyframeThrottled()
            return
        }
        waitingForKeyframe = false

        // Annex-B -> AVCC (độ dài 4 byte big-endian trước mỗi NAL)
        var avcc = Data()
        for nal in sliceNALs {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let count = avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: count)
        }
        guard status == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var sizes = [count]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: desc,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard status == noErr, let sampleBuffer = sample else { return }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags
        ) { [weak self] st, _, imageBuffer, _, _ in
            guard let self = self else { return }
            guard st == noErr, let pixelBuffer = imageBuffer else {
                self.queue.async {
                    self.waitingForKeyframe = true
                    self.requestKeyframeThrottled()
                }
                return
            }
            self.emit(pixelBuffer)
        }

        if decodeStatus == kVTInvalidSessionErr {
            invalidateSession()
            waitingForKeyframe = true
            requestKeyframeThrottled()
        } else if decodeStatus != noErr {
            waitingForKeyframe = true
            requestKeyframeThrottled()
        }
    }

    private func emit(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastOutputTime >= 1.0 / maxOutputFPS else { return }
        lastOutputTime = now
        var cgImage: CGImage?
        _ = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if let img = cgImage {
            onFrame?(img)
        }
    }

    private func requestKeyframeThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastIDRRequest > 1.0 else { return }
        lastIDRRequest = now
        onNeedKeyframe?()
    }

    private func createSession() {
        invalidateSession()
        guard let sps = sps, let pps = pps else { return }
        var desc: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let d = desc else { return }
        formatDesc = d

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var newSession: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: d, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &newSession)
        if st == noErr {
            session = newSession
            waitingForKeyframe = true
        }
    }

    private func invalidateSession() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDesc = nil
    }

    /// Tách các NAL unit từ luồng Annex-B (start code 00 00 01 hoặc 00 00 00 01)
    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var starts: [(pos: Int, len: Int)] = []
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                } else if i + 3 < n && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        var nals: [Data] = []
        for (idx, s) in starts.enumerated() {
            let begin = s.pos + s.len
            var end = idx + 1 < starts.count ? starts[idx + 1].pos : n
            // bỏ byte 0 đệm cuối NAL
            while end > begin && bytes[end - 1] == 0 && idx + 1 < starts.count { end -= 1 }
            if end > begin { nals.append(Data(bytes[begin..<end])) }
        }
        return nals
    }
}

// MARK: - Giữ app chạy nền để không mất Remote Play khi thoát ra ngoài

final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isActive = false
    /// 1.23: người dùng/kết nối muốn chạy nền (để tự bật lại khi iOS ngắt âm thanh: khoá màn hình, cuộc gọi, Siri...)
    private var wanted = false
    private var observersInstalled = false

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.wanted else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self.restart() }
            else { self.markStopped() }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.wanted else { return }
            self.markStopped(); self.restart()
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.wanted else { return }
            self.markStopped(); self.restart()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // vào nền / khoá màn hình: chắc chắn âm thanh im lặng đang chạy, nếu không iOS sẽ treo app sau vài giây
            guard let self = self, self.wanted else { return }
            if self.engine?.isRunning != true { self.markStopped(); self.restart() }
        }
    }

    private func markStopped() {
        player?.stop(); engine?.stop()
        player = nil; engine = nil
        isActive = false
    }

    private func restart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.wanted, !self.isActive else { return }
            self.start()
        }
    }

    /// Phát âm thanh im lặng liên tục (cần UIBackgroundModes = audio trong Info.plist).
    func start() {
        wanted = true
        installObservers()
        guard !isActive else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0

            let frames = AVAudioFrameCount(44100)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames // toàn bộ là 0 = im lặng

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()

            self.engine = engine
            self.player = player
            isActive = true
        } catch {
            isActive = false
        }
    }

    func stop() {
        wanted = false
        guard isActive else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
    }
}
