import UIKit

@_silgen_name("frameProbeInstall") func frameProbeInstall()
@_silgen_name("frameProbeCount") func frameProbeCount() -> Int32
@_silgen_name("frameProbeStage") func frameProbeStage(_ stage: Int32)
@_silgen_name("frameProbeGap") func frameProbeGap(_ stage: Int32) -> Double

/// Samples displayed-frame progress around 1x -> 2.5x -> 1x transitions.
final class RateProbeDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let player = SwiftVlcPlayer()
    var timer: Timer?
    var started = ProcessInfo.processInfo.systemUptime
    var firstFrame: TimeInterval?
    var lastFrame: TimeInterval = 0
    var pictures: Int32 = 0
    var stage = 0
    var maxGap: [TimeInterval] = [0, 0, 0]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        frameProbeInstall()
        let controller = UIViewController()
        controller.view = player.view
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        player.open(uri: "http://127.0.0.1:18765/fixture.mkv", headers: [:], startPositionMillis: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            if now - started > 30 || player.phase == 6 {
                print("VLC_RATE_FAILED: timeout or decoder error"); fflush(stdout); exit(1)
            }
            let count = frameProbeCount()
            if count != pictures {
                if firstFrame != nil { maxGap[stage] = max(maxGap[stage], now - lastFrame) }
                pictures = count
                lastFrame = now
                if firstFrame == nil { firstFrame = now }
            }
            guard let firstFrame else { return }
            let elapsed = now - firstFrame
            if stage == 0 && elapsed >= 0.6 {
                player.setRate(rate: 2.5)
                stage = 1
                frameProbeStage(1)
            } else if stage == 1 && elapsed >= 1.6 {
                player.setRate(rate: 1)
                stage = 2
                frameProbeStage(2)
            } else if stage == 2 && elapsed >= 3.6 {
                maxGap[stage] = max(maxGap[stage], now - lastFrame)
                let cache = ProcessInfo.processInfo.environment["VLC_TEST_CACHE"] ?? "default"
                print("VLC_RATE_RESULT cache=\(cache) gap_ms=\((0...2).map { Int(frameProbeGap(Int32($0)) * 1000) }) frames=\(count)")
                player.close()
                fflush(stdout)
                exit(0)
            }
        }
        return true
    }
}
