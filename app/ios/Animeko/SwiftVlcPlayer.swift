import UIKit
import AVFAudio
import MobileVLCKit
#if canImport(application)
import application
#endif

/// VLC demuxes and decodes the original file, including embedded subtitles and fonts.
final class SwiftVlcPlayer: NSObject, IosVlcPlayer, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private let surface = VlcSurface()
    private var interrupted: NSObjectProtocol?
    private var routeChanged: NSObjectProtocol?
    private var generation = 0
    private var opening = false
    private var terminalPhase: Int32?
    private var nativePaused = false
    private var aspect: Int32 = 0
    private var aspectString: UnsafeMutablePointer<CChar>?
    private var cropString: UnsafeMutablePointer<CChar>?

    override init() {
        super.init()
        surface.backgroundColor = .black
        player.drawable = surface
        player.delegate = self
        #if VLC_TESTING
        player.libraryInstance.debugLogging = true
        player.libraryInstance.debugLoggingLevel = 4
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
    var positionMillis: Int64 { max(0, Int64(player.time.intValue)) }
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
        media.addOption(":network-caching=1500")
        media.addOption(":file-caching=500")
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
        terminalPhase = nil
        nativePaused = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }
    func pause() { player.pause() }
    func stop() {
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
        player.time = VLCTime(int: Int32(clamping: positionMillis))
    }
    func setRate(rate: Float) { player.rate = rate }
    func setVolume(volume: Float, muted: Bool) {
        player.audio?.volume = Int32(min(2, max(0, volume)) * 100)
        player.audio?.isMuted = muted
    }
    func selectAudio(id: Int32) { player.currentAudioTrackIndex = id }
    func selectSubtitle(id: Int32) { player.currentVideoSubTitleIndex = id }
    func addSubtitle(uri: String) {
        if let url = URL(string: uri) { player.addPlaybackSlave(url, type: .subtitle, enforce: false) }
    }
    func setAspect(mode: Int32) { aspect = mode; updateAspect() }
    private func updateAspect() {
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
