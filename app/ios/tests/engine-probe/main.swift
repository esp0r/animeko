import UIKit
import AVFAudio
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import VLCKit
#endif

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
    let player = VLCMediaPlayer()
    let logger = ProbeLogger()
    var timer: Timer?
    var start = ProcessInfo.processInfo.systemUptime
    var ready: TimeInterval?
    var step = 0
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
        let url = Bundle.main.url(forResource: "fixture", withExtension: "mkv")!
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
                player.rate = rate
                step += 1
            }
            if step == 6 && now - ready >= 16 {
                let stats = media.statistics
                guard player.time.intValue > 20000, stats.displayedPictures > 200, stats.playedAudioBuffers > 100, abs(player.rate - 1.25) < 0.01 else {
                    print("ENGINE_PROBE_FAILED: playback did not advance"); fflush(stdout); exit(1)
                }
                print("ENGINE_PROBE_PASSED position=\(player.time.intValue) frames=\(stats.displayedPictures) lost=\(stats.lostPictures) audio=\(stats.playedAudioBuffers)")
                fflush(stdout)
                timer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Probe.self))
