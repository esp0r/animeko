import UIKit
import AVFAudio
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import VLCKit
#endif

@_silgen_name("frameProbeInstall") func frameProbeInstall()
@_silgen_name("frameProbeCount") func frameProbeCount() -> Int32
@_silgen_name("frameProbeStage") func frameProbeStage(_ stage: Int32)
@_silgen_name("frameProbeGap") func frameProbeGap(_ stage: Int32) -> Double

final class ProbeLogger: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let text = message.lowercased()
        if ["silence", "flushing", "too early", "too late", "clock", "resampl"].contains(where: text.contains) {
            print("SYNC \(ProcessInfo.processInfo.systemUptime) \(message)")
            fflush(stdout)
        }
    }
}

final class Probe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let player = VLCMediaPlayer(options: {
        let environment = ProcessInfo.processInfo.environment
        var options = environment["VLC_PROBE_CLOCK"].map { ["--clock-master=\($0)"] } ?? []
        if environment["VLC_PROBE_LEGACY"] == "1" { options.append("--force-darwin-legacy-display") }
        return options
    }())
    let logger = ProbeLogger()
    var timer: Timer?
    var start = ProcessInfo.processInfo.systemUptime
    var ready: TimeInterval?
    var step = 0
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        frameProbeInstall()
        let view = UIView()
        view.backgroundColor = .black
        let controller = UIViewController()
        controller.view = view
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        player.drawable = view
        player.libraryInstance.loggers = [logger]
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let fixture = ProcessInfo.processInfo.environment["VLC_PROBE_CODEC"] == "hevc" ? "rate-hevc-fixture" : "rate-fixture"
        let url = Bundle.main.url(forResource: fixture, withExtension: "mkv")!
        #if canImport(MobileVLCKit)
        let media = VLCMedia(url: url)
        #else
        guard let media = VLCMedia(url: url) else { return false }
        #endif
        media.addOption(":file-caching=100")
        player.media = media
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            if now - start > 45 || player.state == .error {
                print("ENGINE_PROBE_FAILED: playback unavailable"); fflush(stdout); exit(1)
            }
            if ready == nil && player.time.intValue > 1500 {
                ready = now
                player.rate = 1.25
            }
            guard let ready else { return }
            if step < 6 && now - ready >= 3 + Double(step) * 2 {
                let rate: Float = step % 2 == 0 ? 2.5 : 1.25
                print("RATE \(now) target=\(rate) position=\(player.time.intValue)")
                frameProbeStage(step % 2 == 0 ? 1 : 2)
                player.rate = rate
                step += 1
            }
            if step == 6 && now - ready >= 16 {
                let stats = media.statistics
                guard player.time.intValue > 20000, stats.displayedPictures > 200, stats.playedAudioBuffers > 100, abs(player.rate - 1.25) < 0.01 else {
                    print("ENGINE_PROBE_FAILED: playback did not advance"); fflush(stdout); exit(1)
                }
                print("ENGINE_PROBE_PASSED position=\(player.time.intValue) frames=\(stats.displayedPictures) lost=\(stats.lostPictures) audio=\(stats.playedAudioBuffers)")
                print("DRAWABLE frames=\(frameProbeCount()) gaps_ms=\((0...2).map { Int(frameProbeGap(Int32($0)) * 1000) })")
                fflush(stdout)
                timer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Probe.self))
