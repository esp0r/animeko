import UIKit
import AVFAudio
import CoreText
import MobileVLCKit
#if canImport(application)
import application
#endif

/// VLC demuxes and decodes the original file, including embedded subtitles and fonts.
final class SwiftVlcPlayer: NSObject, IosVlcPlayer, VLCMediaPlayerDelegate {
    private let player = SwiftVlcPlayer.makePlayer()
    private let surface = VlcSurface()
    private var interrupted: NSObjectProtocol?
    private var routeChanged: NSObjectProtocol?
    private var generation = 0
    private var opening = false
    private var terminalPhase: Int32?
    private var nativePaused = false
    private var pausedSeek: Int64?
    private var seekResumeDeadline: TimeInterval?
    private static let subtitleScaleKey = "animeko.vlc.subtitleScale"
    private(set) var subtitleScale: Float = {
        let saved = UserDefaults.standard.object(forKey: SwiftVlcPlayer.subtitleScaleKey) as? NSNumber
        let value = saved?.floatValue ?? 1
        return value.isFinite ? min(2, max(0.5, value)) : 1
    }()
    private var aspect: Int32 = 0
    private var aspectString: UnsafeMutablePointer<CChar>?
    private var cropString: UnsafeMutablePointer<CChar>?
    private var subtitleRefresh: DispatchWorkItem?
    #if VLC_TESTING
    private var rateRevision = 0
    #endif

    // FreeType needs a readable font file as well as a CoreText family match.
    // Bundling the font keeps CJK captions independent of system font storage.
    private static let subtitleFont: URL? = {
        guard let url = Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf", subdirectory: "SubtitleFonts") else {
            NSLog("Animeko VLC: bundled subtitle font is missing")
            return nil
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            NSLog("Animeko VLC: subtitle font registration: %@", String(describing: error?.takeRetainedValue()))
        }
        return url
    }()

    private static func makePlayer() -> VLCMediaPlayer {
        guard let font = subtitleFont else { return VLCMediaPlayer() }
        return VLCMediaPlayer(options: [
            "--freetype-font=Noto Sans CJK SC",
            "--freetype-monofont=Noto Sans CJK SC",
            "--ssa-fontsdir=\(font.deletingLastPathComponent().path)",
        ])
    }

    override init() {
        super.init()
        surface.backgroundColor = .black
        player.drawable = surface
        player.delegate = self
        applySubtitleScale()
        #if VLC_TESTING
        let consoleLogger = VLCConsoleLogger()
        consoleLogger.level = .debug
        player.libraryInstance.loggers = [PlayerDiagnostics.shared, consoleLogger]
        #elseif DEBUG
        player.libraryInstance.loggers = [PlayerDiagnostics.shared]
        #endif
        surface.onLayout = { [weak self] in self?.updateAspect() }
        let center = NotificationCenter.default
        interrupted = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                self?.pause()
            }
        }
        routeChanged = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self?.pause()
            }
        }
    }

    var view: UIView { surface }
    var phase: Int32 {
        if opening { return 1 }
        if let terminalPhase { return terminalPhase }
        switch player.state {
        case .stopped: return 0
        case .opening: return 1
        // VLCKit caches buffering notifications even after their percentage reaches 100.
        // Read libvlc's transport instead of treating the last notification as a stall.
        case .buffering: return nativePaused ? 4 : (player.isPlaying ? 3 : 2)
        case .playing: return 3
        case .paused: return 4
        case .ended: return 5
        case .error: return 6
        default: return nativePaused ? 4 : (player.isPlaying ? 3 : 1)
        }
    }
    var positionMillis: Int64 {
        let actual = max(0, Int64(player.time.intValue))
        guard let target = pausedSeek else { return actual }
        // libvlc accepts paused seeks, but VLCKit's cached clock updates on resume.
        if abs(actual - target) < 750 || (seekResumeDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false) {
            pausedSeek = nil
            seekResumeDeadline = nil
            return actual
        }
        return target
    }
    #if VLC_TESTING
    var nativePositionMillis: Int64 { max(0, Int64(player.time.intValue)) }
    #endif
    var durationMillis: Int64 { max(0, Int64(player.media?.length.intValue ?? 0)) }
    var videoWidth: Int32 { Int32(player.videoSize.width) }
    var videoHeight: Int32 { Int32(player.videoSize.height) }
    var seekable: Bool { player.isSeekable }
    var selectedAudio: Int32 { player.currentAudioTrackIndex }
    var selectedSubtitle: Int32 { player.currentVideoSubTitleIndex }

    private func tracks(_ ids: [Any], _ names: [Any]) -> [IosVlcTrack] {
        zip(ids, names).compactMap { id, name in
            guard let id = id as? NSNumber, id.int32Value >= 0 else { return nil }
            return IosVlcTrack(id: id.int32Value, name: String(describing: name))
        }
    }
    var audioTracks: [IosVlcTrack] { tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var subtitleTracks: [IosVlcTrack] { tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames) }

    func open(uri: String, headers: [String: String], startPositionMillis: Int64) {
        stop()
        guard let url = URL(string: uri) else { return }
        let media = VLCMedia(url: url)
        #if VLC_TESTING
        let testCache = ProcessInfo.processInfo.environment["VLC_TEST_CACHE"] ?? "1500"
        media.addOption(":network-caching=\(testCache)")
        #else
        media.addOption(":network-caching=1500")
        #endif
        #if VLC_TESTING
        let fileCache = ProcessInfo.processInfo.environment["VLC_TEST_CACHE"] ?? "500"
        media.addOption(":file-caching=\(fileCache)")
        #else
        media.addOption(":file-caching=500")
        #endif
        if startPositionMillis > 0 {
            media.addOption(":start-time=\(Double(startPositionMillis) / 1000)")
        }
        for (name, value) in headers where !value.contains("\r") && !value.contains("\n") {
            switch name.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer": media.addOption(":http-referrer=\(value)")
            case "cookie": media.addOption(":http-cookie=\(value)")
            default: break
            }
        }
        opening = true
        let load = generation
        func attachWhenStopped() {
            guard generation == load else { return }
            if player.media != nil && player.state != .stopped {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard self != nil else { return }
                    attachWhenStopped()
                }
                return
            }
            player.media = media
            NSLog("Animeko VLC: opening %@ media", url.isFileURL ? "local" : "network")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == load else { return }
                self.opening = false
                self.play()
            }
        }
        attachWhenStopped()
    }

    func play() {
        #if DEBUG || VLC_TESTING
        diagnosticSnapshot("play requested")
        #endif
        if pausedSeek != nil { seekResumeDeadline = ProcessInfo.processInfo.systemUptime + 5 }
        terminalPhase = nil
        nativePaused = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }
    func pause() {
        #if DEBUG || VLC_TESTING
        diagnosticSnapshot("pause requested")
        #endif
        player.pause()
    }
    func stop() {
        subtitleRefresh?.cancel()
        subtitleRefresh = nil
        pausedSeek = nil
        seekResumeDeadline = nil
        generation += 1
        opening = false
        terminalPhase = nil
        // stop is asynchronous; keep the media until VLC has acknowledged it.
        if player.media != nil { player.stop() }
    }
    func mediaPlayerStateChanged(_ notification: Notification) {
        if player.state == .paused { nativePaused = true }
        if player.state == .playing || player.state == .stopped { nativePaused = false }
        if player.state == .ended { terminalPhase = 5 }
        if player.state == .error { terminalPhase = 6 }
        NSLog("Animeko VLC: phase=%d time=%lld size=%dx%d", phase, positionMillis, videoWidth, videoHeight)
    }
    func close() {
        stop()
        player.drawable = nil
        player.delegate = nil
        Self.releaseStoppedMedia(player)
        surface.onLayout = nil
        if let interrupted { NotificationCenter.default.removeObserver(interrupted) }
        if let routeChanged { NotificationCenter.default.removeObserver(routeChanged) }
        interrupted = nil
        routeChanged = nil
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil
        free(aspectString); aspectString = nil
        free(cropString); cropString = nil
    }
    private static func releaseStoppedMedia(_ player: VLCMediaPlayer) {
        if player.state == .stopped {
            player.media = nil
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { releaseStoppedMedia(player) }
        }
    }
    func seek(positionMillis: Int64) {
        #if DEBUG || VLC_TESTING
        diagnosticSnapshot("seek requested target=\(positionMillis)")
        #endif
        guard player.isSeekable else { return }
        let target = max(0, durationMillis > 0 ? min(positionMillis, durationMillis) : positionMillis)
        if nativePaused || player.state == .paused {
            pausedSeek = target
            seekResumeDeadline = nil
        } else {
            pausedSeek = nil
        }
        player.time = VLCTime(int: Int32(clamping: target))
    }
    func setRate(rate: Float) {
        #if DEBUG || VLC_TESTING
        PlayerDiagnostics.shared.arm()
        diagnosticSnapshot("rate request=\(rate) native=\(player.rate)")
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        #if VLC_TESTING
        let ramp = Double(ProcessInfo.processInfo.environment["VLC_TEST_RATE_RAMP"] ?? "0") ?? 0
        rateRevision += 1
        let revision = rateRevision
        let loadGeneration = generation
        let initial = player.rate
        if ramp > 0 && player.isPlaying && player.time.intValue > 0 {
            let steps = max(1, Int(ramp / 0.025))
            for step in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + ramp * Double(step) / Double(steps)) { [weak self] in
                    guard let self, self.rateRevision == revision, self.generation == loadGeneration else { return }
                    self.player.rate = initial + (rate - initial) * Float(step) / Float(steps)
                }
            }
        } else {
            player.rate = rate
        }
        #else
        player.rate = rate
        #endif
        #if DEBUG || VLC_TESTING
        diagnosticSnapshot("rate returned elapsedMs=\((ProcessInfo.processInfo.systemUptime - began) * 1000)")
        let load = generation
        for delay in [0.05, 0.15, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == load else { return }
                self.diagnosticSnapshot("rate sample after=\(delay) requested=\(rate)")
            }
        }
        #endif
    }

    #if DEBUG || VLC_TESTING
    private func diagnosticSnapshot(_ event: String) {
        let stats = player.media?.statistics
        PlayerDiagnostics.shared.record("\(event) phase=\(phase) position=\(positionMillis) nativeRate=\(player.rate) frames=\(stats?.displayedPictures ?? 0) lost=\(stats?.lostPictures ?? 0) audio=\(stats?.playedAudioBuffers ?? 0) audioLost=\(stats?.lostAudioBuffers ?? 0)")
    }
    #endif
    func setVolume(volume: Float, muted: Bool) {
        player.audio?.volume = Int32(min(2, max(0, volume)) * 100)
        player.audio?.isMuted = muted
    }
    func selectAudio(id: Int32) { player.currentAudioTrackIndex = id }
    func setSubtitleScale(scale: Float) {
        subtitleScale = scale.isFinite ? min(2, max(0.5, scale)) : 1
        UserDefaults.standard.set(subtitleScale, forKey: Self.subtitleScaleKey)
        applySubtitleScale()
        subtitleRefresh?.cancel()
        // A decoded text cue retains its rendered bitmap. Seeking to the current
        // position re-decodes that cue without changing the play/pause intent.
        // Coalesce slider events to avoid repeated decoder flushes while dragging.
        let refresh = DispatchWorkItem { [weak self] in
            guard let self, self.player.isSeekable, self.selectedSubtitle >= 0,
                  self.phase == 3 || self.phase == 4 else { return }
            self.seek(positionMillis: self.positionMillis)
        }
        subtitleRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: refresh)
    }

    private func applySubtitleScale() {
        // MobileVLCKit 3 exposes this Objective-C setter without a public header declaration.
        // FreeType uses a divisor of video height: a smaller divisor produces larger text.
        let setter = NSSelectorFromString("setTextRendererFontSize:")
        guard player.responds(to: setter) else {
            assertionFailure("MobileVLCKit is missing the text renderer size setter")
            return
        }
        player.perform(setter, with: NSNumber(value: Int((16 / subtitleScale).rounded())))
    }

    func selectSubtitle(id: Int32) { player.currentVideoSubTitleIndex = id }
    func addSubtitle(uri: String) {
        if let url = URL(string: uri) { player.addPlaybackSlave(url, type: .subtitle, enforce: false) }
    }
    func setAspect(mode: Int32) { aspect = mode; updateAspect() }
    private func updateAspect() {
        #if DEBUG || VLC_TESTING
        PlayerDiagnostics.shared.record("layout mode=\(aspect) size=\(surface.bounds.size)")
        #endif
        guard surface.bounds.width > 0, surface.bounds.height > 0 else { return }
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil
        free(aspectString); aspectString = nil
        free(cropString); cropString = nil
        let ratio = "\(Int(surface.bounds.width)):\(Int(surface.bounds.height))"
        if aspect == 1 { aspectString = strdup(ratio); player.videoAspectRatio = aspectString }
        if aspect == 2 { cropString = strdup(ratio); player.videoCropGeometry = cropString }
        player.scaleFactor = 0
    }
}

private final class VlcSurface: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}

#if DEBUG || VLC_TESTING
/// Bounded local diagnostics around a rate change; disk writes run off the UI thread.
private final class PlayerDiagnostics: NSObject, VLCLogging {
    static let shared = PlayerDiagnostics()
    var level: VLCLogLevel = .debug
    private let queue = DispatchQueue(label: "animeko.player-diagnostics")
    private let lock = NSLock()
    private var deadline: TimeInterval = 0
    private var file: FileHandle?
    private var bytes = 0

    override init() {
        super.init()
        queue.async { [self] in
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = directory.appendingPathComponent("animeko-player-diagnostics.log")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try? FileHandle(forWritingTo: url)
        }
    }

    func arm() {
        lock.lock()
        deadline = ProcessInfo.processInfo.systemUptime + 8
        lock.unlock()
    }

    func record(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let enabled = now <= deadline
        lock.unlock()
        guard enabled else { return }
        let line = String(format: "%.6f ", now) + message + "\n"
        queue.async { [self] in
            guard let data = line.data(using: .utf8), bytes + data.count <= 2 * 1024 * 1024 else { return }
            try? file?.write(contentsOf: data)
            bytes += data.count
        }
    }

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let text = message.lowercased()
        guard !text.contains("://"), !text.contains("cookie"), !text.contains("authorization"),
              ["late", "early", "resampl", "silence", "flush", "buffer", "rate", "clock", "discontinu", "decoder", "vout"].contains(where: text.contains) else { return }
        record("vlc[\(context?.module ?? "unknown")] \(message)")
    }
}
#endif
