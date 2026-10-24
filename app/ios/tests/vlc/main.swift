import UIKit
import CoreText

final class TestDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let player = SwiftVlcPlayer()
    var timer: Timer?
    var step = 0
    var tick = 0
    var pausedAt: Int64 = 0
    var pausedTick = 0
    func require(_ condition: Bool, _ message: String) {
        if !condition { print("VLC_TEST_FAILED: \(message)"); fflush(stdout); exit(1) }
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view = player.view
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        let font = CTFontCreateWithName("Noto Sans CJK SC" as CFString, 24, nil)
        let sample = Array("简体中文测试繁體字幕日本語한국어".utf16)
        var glyphs = Array(repeating: CGGlyph(0), count: sample.count)
        require(CTFontGetGlyphsForCharacters(font, sample, &glyphs, sample.count), "bundled font missing CJK glyphs")
        let fontURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
        require(fontURL?.lastPathComponent == "NotoSansCJKsc-Regular.otf", "CoreText did not select bundled font")
        let url = Bundle.main.url(forResource: "fixture", withExtension: "mkv")!
        player.open(uri: url.absoluteString, headers: [:], startPositionMillis: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            tick += 1
            if tick % 10 == 0 { print("VLC_TEST: step=\(step) phase=\(player.phase) position=\(player.positionMillis)"); fflush(stdout) }
            require(tick < 450, "timed out at step \(step), phase \(player.phase)")
            require(player.phase != 6, "decoder error")
            switch step {
            case 0 where player.phase == 3 && player.positionMillis > 1200:
                require(player.videoWidth == 640 && player.videoHeight == 360, "video dimensions")
                require(player.durationMillis >= 7500, "duration")
                require(!player.audioTracks.isEmpty, "AAC track missing")
                require(!player.subtitleTracks.isEmpty, "embedded SRT missing")
                require(player.selectedSubtitle == player.subtitleTracks[0].id, "default Chinese subtitle not selected")
                player.selectAudio(id: player.audioTracks[0].id)
                player.setAspect(mode: 2)
                player.setVolume(volume: 0.5, muted: false)
                player.pause()
                step = 1
            case 1 where player.phase == 4:
                pausedAt = player.positionMillis
                pausedTick = tick
                print("VLC_SUBTITLE_READY"); fflush(stdout)
                step = 2
            case 2 where tick - pausedTick >= 100:
                require(abs(player.positionMillis - pausedAt) < 200, "pause did not hold position")
                require(player.seekable, "local MKV is not seekable")
                player.seek(positionMillis: 4000)
                step = 3
            case 3 where abs(player.positionMillis - 4000) < 750:
                require(player.phase == 4, "seek resumed paused playback")
                player.setRate(rate: 1.5)
                player.play()
                step = 4
            case 4 where player.phase == 3 && player.nativePositionMillis >= 4000:
                require(player.nativePositionMillis < 6500, "resume missed the seek target")
                print("VLC_TEST: confirmed native seek at \(player.nativePositionMillis)")
                step = 5
            case 5 where player.phase == 5:
                player.close()
                print("VLC_TEST_PASSED: original MKV decoded; tracks, pause, seek, speed, end and cleanup")
                fflush(stdout)
                exit(0)
            default: break
            }
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(TestDelegate.self))
