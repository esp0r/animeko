import Foundation
import Vision

func captionHeight(_ path: String) throws -> CGFloat {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.005
    try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
    let results = request.results ?? []
    let text = results.compactMap { $0.topCandidates(1).first?.string }.joined()
    print("VLC_SUBTITLE_OCR: \(text)")
    guard text.contains("简体中文测试"), text.contains("繁體中文字幕") else {
        fputs("VLC_TEST_FAILED: rendered Chinese captions are missing or unreadable\n", stderr)
        exit(1)
    }
    return results.filter { $0.topCandidates(1).first?.string.contains("中文") == true }
        .map { $0.boundingBox.height }.max() ?? 0
}
let normal = try captionHeight(CommandLine.arguments[1])
let large = try captionHeight(CommandLine.arguments[2])
print("VLC_SUBTITLE_SIZE: normal=\(normal), large=\(large)")
guard normal > 0, large > normal * 1.2, large < normal * 1.9 else {
    fputs("VLC_TEST_FAILED: changing subtitle size did not resize rendered glyphs\n", stderr)
    exit(1)
}
print("VLC_SUBTITLE_TEST_PASSED: Chinese glyphs and live subtitle resizing verified")
