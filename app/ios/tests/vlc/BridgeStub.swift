import UIKit

// Mirrors the exported Kotlin protocol so the native engine can be tested independently.
protocol IosVlcPlayer {
    var view: UIView { get }
    var phase: Int32 { get }
    var positionMillis: Int64 { get }
    var durationMillis: Int64 { get }
    var videoWidth: Int32 { get }
    var videoHeight: Int32 { get }
    var seekable: Bool { get }
    var audioTracks: [IosVlcTrack] { get }
    var subtitleTracks: [IosVlcTrack] { get }
    var selectedAudio: Int32 { get }
    var selectedSubtitle: Int32 { get }
    func open(uri: String, headers: [String: String], startPositionMillis: Int64)
    func play()
    func pause()
    func stop()
    func close()
    func seek(positionMillis: Int64)
    func setRate(rate: Float)
    func setVolume(volume: Float, muted: Bool)
    func setAspect(mode: Int32)
    func selectAudio(id: Int32)
    func selectSubtitle(id: Int32)
    func addSubtitle(uri: String)
}
final class IosVlcTrack {
    let id: Int32
    let name: String
    init(id: Int32, name: String) { self.id = id; self.name = name }
}
