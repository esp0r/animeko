import Foundation
import Vision

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
request.usesLanguageCorrection = false
request.minimumTextHeight = 0.005
let handler = VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]))
try handler.perform([request])
let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
print("VLC_SUBTITLE_OCR: \(text)")
guard text.contains("简体中文测试"), text.contains("繁體中文字幕") else {
    fputs("VLC_TEST_FAILED: rendered Chinese captions are missing or unreadable\n", stderr)
    exit(1)
}
print("VLC_SUBTITLE_TEST_PASSED: simplified and traditional Chinese rendered by VLC")
