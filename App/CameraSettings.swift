import Foundation
import AVFoundation

public enum CameraMode: String, CaseIterable, Codable, Identifiable {
    case timeLapse = "TIME-LAPSE", slowMotion = "SLO-MO", video = "VIDEO", photo = "PHOTO"
    public var id: String { rawValue }
    var isMovie: Bool { self != .photo }
}
enum Framing: String, CaseIterable, Codable, Identifiable {
    case portrait = "9:16", landscape = "16:9", square = "1:1", classic = "3:4"
    var id: String { rawValue }
    var ratio: Double {
        switch self { case .portrait: return 9/16; case .landscape: return 16/9; case .square: return 1; case .classic: return 3/4 }
    }
    func size(longEdge: Int) -> Size2 {
        let edge = Double(longEdge)
        // Encoder dimensions must be even.
        func even(_ v: Double) -> Double { Double(Int(v / 2) * 2) }
        return ratio >= 1 ? Size2(edge, even(edge / ratio)) : Size2(even(edge * ratio), edge)
    }
}
enum Resolution: String, CaseIterable, Codable, Identifiable {
    case fullHD = "1080p", ultraHD = "4K"
    var id: String { rawValue }
    var longEdge: Int { self == .ultraHD ? 3840 : 1920 }
}
enum FlashChoice: String, CaseIterable, Codable, Identifiable {
    case off = "Off", auto = "Auto", on = "On"
    var id: String { rawValue }
    var avMode: AVCaptureDevice.FlashMode {
        switch self { case .off: return .off; case .auto: return .auto; case .on: return .on }
    }
}
enum CaptureFilter: String, CaseIterable, Codable, Identifiable {
    case original = "Original", vivid = "Vivid", noir = "Noir", warm = "Warm", cool = "Cool"
    var id: String { rawValue }
}
enum CodecChoice: String, CaseIterable, Codable, Identifiable {
    case efficient = "HEVC / HEIF", compatible = "H.264 / JPEG"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .efficient ? .hevc : .h264 }
}
struct CameraSettings: Codable, Equatable {
    var mode: CameraMode = .video
    var videoFraming: Framing = .portrait
    var photoFraming: Framing = .classic
    var resolution: Resolution = .fullHD
    var fps = 30
    var horizonLock = true
    var zoomLock = false
    var zoom = 1.0
    var grid = true
    var showLevel = true
    var showOverview = true
    var mirrorSelfie = true
    var flash: FlashChoice = .off
    var torch = false
    var livePhoto = false
    var raw = false
    var timer = 0
    var filter: CaptureFilter = .original
    var codec: CodecChoice = .efficient
    var exposureEV: Float = 0
    var aeafLock = false
    var manualFocus = false
    var lensPosition: Float = 0.5
    var manualExposure = false
    var iso: Float = 100
    var shutterDenominator = 125.0
    var whiteBalanceLock = false
    var audio = true
    var saveToPhotos = true
    var timeLapseInterval = 0.5
    var horizonTrimDegrees = 0.0
    var motionOffsetMilliseconds = 0.0
    var framing: Framing { mode == .photo ? photoFraming : videoFraming }
    var isProcessedPhoto: Bool { horizonLock || zoomLock || zoom > 1.001 || filter != .original }
    var captureFPS: Int { mode == .slowMotion ? 120 : fps }
    var outputSize: Size2 { framing.size(longEdge: mode == .slowMotion ? 1920 : resolution.longEdge) }
    var reserve: Double { zoomLock ? 0.80 : (horizonLock ? 0.97 : 1) }
    var cadence: RecordingCadence {
        switch mode {
        case .slowMotion: return .slowMotion(captureFPS: 120, playbackFPS: 30)
        case .timeLapse: return .timeLapse(interval: timeLapseInterval, playbackFPS: 30)
        default: return .realtime
        }
    }
}
struct LensOption: Identifiable, Equatable {
    let id: String
    let label: String
    let name: String
    let isFront: Bool
}
struct CameraCapabilities {
    var lenses: [LensOption] = []
    var selectedLens = ""
    var flash = false
    var torch = false
    var livePhoto = false
    var raw = false
    var manualFocus = false
    var maxISO: Float = 1600
    var minISO: Float = 25
    var minEV: Float = -2
    var maxEV: Float = 2
    var supports4K = false
    var supports60 = false
    var supports120 = false
    var sourceDescription = "Starting camera…"
}
struct FrameDiagnostics {
    var rollDegrees = 0.0
    var motionStatus = "Starting motion…"
    var trackingStatus = "Off"
    var confidence: Float = 0
    var edgeLimited = false
    var detail = Size2(0, 0)
    var upscaled = false
    var deliveredFPS = 0.0
    var droppedFrames = 0
    var recordingSeconds = 0.0
}
enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
