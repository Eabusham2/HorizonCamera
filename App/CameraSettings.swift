import Foundation
import AVFoundation

public enum CameraMode: String, CaseIterable, Codable, Identifiable {
    case timeLapse = "TIME-LAPSE", slowMotion = "SLO-MO", cinematic = "CINEMATIC", video = "VIDEO", photo = "PHOTO", spatial = "SPATIAL"
    public var id: String { rawValue }
    var isMovie: Bool { self != .photo }
    var isNativeMovieMode: Bool { self == .cinematic || self == .spatial }
}

enum Framing: String, CaseIterable, Codable, Identifiable {
    case portrait = "9:16", landscape = "16:9", square = "1:1", classic = "3:4"
    var id: String { rawValue }
    var ratio: Double {
        switch self { case .portrait: return 9/16; case .landscape: return 16/9; case .square: return 1; case .classic: return 3/4 }
    }
    func size(longEdge: Int) -> Size2 {
        let edge = Double(longEdge)
        func even(_ value: Double) -> Double { Double(Int(value / 2) * 2) }
        return ratio >= 1 ? Size2(edge, even(edge / ratio)) : Size2(even(edge * ratio), edge)
    }
}

enum Resolution: String, CaseIterable, Codable, Identifiable {
    case hd = "720p", fullHD = "1080p", ultraHD = "4K"
    var id: String { rawValue }
    var longEdge: Int { switch self { case .hd: return 1280; case .fullHD: return 1920; case .ultraHD: return 3840 } }
}

enum FlashChoice: String, CaseIterable, Codable, Identifiable {
    case off = "Off", auto = "Auto", on = "On"
    var id: String { rawValue }
    var avMode: AVCaptureDevice.FlashMode { switch self { case .off: return .off; case .auto: return .auto; case .on: return .on } }
}

enum CaptureFilter: String, CaseIterable, Codable, Identifiable {
    case original = "Original", vivid = "Vivid", noir = "Noir", warm = "Warm", cool = "Cool"
    var id: String { rawValue }
}

enum CodecChoice: String, CaseIterable, Codable, Identifiable {
    case efficient = "HEVC / HEIF", compatible = "H.264 / JPEG", proResLT = "Apple ProRes 422 LT", proRes422 = "Apple ProRes 422", proResHQ = "Apple ProRes 422 HQ"
    var id: String { rawValue }
    var isProRes: Bool { self == .proResLT || self == .proRes422 || self == .proResHQ }
    var avCodec: AVVideoCodecType {
        switch self {
        case .efficient: return .hevc
        case .compatible: return .h264
        case .proResLT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proResHQ: return .proRes422HQ
        }
    }
}

enum VideoColorProfile: String, CaseIterable, Codable, Identifiable {
    case sdr = "SDR / Rec.709", hdrHLG = "HDR / HLG", appleLog = "Apple Log", appleLog2 = "Apple Log 2"
    var id: String { rawValue }
    var isLog: Bool { self == .appleLog || self == .appleLog2 }
}

enum StabilizationChoice: String, CaseIterable, Codable, Identifiable {
    case off = "Off", standard = "Standard", cinematic = "Cinematic", extended = "Cinematic Extended", enhanced = "Extended Enhanced", previewOptimized = "Preview Optimized", auto = "Auto", lowLatency = "Low Latency"
    var id: String { rawValue }
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .extended: return .cinematicExtended
        case .auto: return .auto
        case .enhanced:
            if #available(iOS 18.0, *) { return .cinematicExtendedEnhanced }
            return .cinematicExtended
        case .previewOptimized:
            if #available(iOS 26.0, *) { return .previewOptimized }
            return .standard
        case .lowLatency:
            if #available(iOS 26.0, *) { return .lowLatency }
            return .standard
        }
    }
}

enum FocusRangeChoice: String, CaseIterable, Codable, Identifiable {
    case full = "Full", near = "Near", far = "Far"
    var id: String { rawValue }
    var avValue: AVCaptureDevice.AutoFocusRangeRestriction { switch self { case .full: return .none; case .near: return .near; case .far: return .far } }
}

enum PhotoQualityChoice: String, CaseIterable, Codable, Identifiable {
    case speed = "Speed", balanced = "Balanced", quality = "Quality"
    var id: String { rawValue }
    var avValue: AVCapturePhotoOutput.QualityPrioritization { switch self { case .speed: return .speed; case .balanced: return .balanced; case .quality: return .quality } }
}

enum AudioCaptureMode: String, CaseIterable, Codable, Identifiable {
    case mono = "Mono", stereo = "Stereo", spatial = "Spatial / Ambisonic"
    var id: String { rawValue }
}

struct CameraSettings: Codable, Equatable {
    var mode: CameraMode = .video
    var videoFraming: Framing = .portrait
    var photoFraming: Framing = .classic
    var resolution: Resolution = .fullHD
    var fps = 30
    var slowMotionFPS = 120
    var autoFPS = false
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
    var colorProfile: VideoColorProfile = .sdr
    var stabilization: StabilizationChoice = .auto
    var exposureEV: Float = 0
    var aeafLock = false
    var manualFocus = false
    var lensPosition: Float = 0.5
    var smoothAutofocus = true
    var faceDrivenAutofocus = true
    var focusRange: FocusRangeChoice = .full
    var manualExposure = false
    var iso: Float = 100
    var shutterDenominator = 125.0
    var whiteBalanceLock = false
    var audio = true
    var audioMode: AudioCaptureMode = .mono
    var windNoiseRemoval = true
    var saveToPhotos = true
    var timeLapseInterval = 0.5
    var responsiveCapture = true
    var zeroShutterLag = true
    var fastCapturePrioritization = true
    var autoDeferredPhotoDelivery = true
    var photoQuality: PhotoQualityChoice = .quality
    var cinematicAperture: Float = 4.0
    var metadataAuthor = ""
    var metadataCopyright = ""
    var metadataDescription = ""
    var horizonTrimDegrees = 0.0
    var motionOffsetMilliseconds = 0.0

    var framing: Framing { mode == .photo ? photoFraming : videoFraming }
    var isProcessedPhoto: Bool { mode == .photo && (horizonLock || zoomLock || zoom > 1.001 || filter != .original || photoFraming != .classic) }
    var captureFPS: Int { mode == .slowMotion ? slowMotionFPS : fps }
    var outputSize: Size2 { framing.size(longEdge: mode == .slowMotion ? min(1920, resolution.longEdge) : resolution.longEdge) }
    var reserve: Double { zoomLock ? 0.80 : (horizonLock ? 0.97 : 1) }
    var usesNativeMoviePipeline: Bool { mode.isNativeMovieMode || codec.isProRes || colorProfile != .sdr || audioMode != .mono }

    mutating func normalize(changedFrom old: CameraSettings) {
        zoom = min(max(zoom, 1), 12)
        if mode == .photo {
            if codec.isProRes { codec = .efficient }
            colorProfile = .sdr
            audioMode = .mono
        }
        if mode == .slowMotion {
            slowMotionFPS = slowMotionFPS >= 240 ? 240 : 120
            codec = .efficient
            colorProfile = .sdr
            audioMode = .mono
        }
        if mode == .timeLapse {
            codec = .efficient
            colorProfile = .sdr
            audioMode = .mono
        }
        if colorProfile.isLog && !codec.isProRes { codec = .proRes422 }
        if mode.isNativeMovieMode || (mode.isMovie && usesNativeMoviePipeline) {
            horizonLock = false
            zoomLock = false
            filter = .original
        }
        if isProcessedPhoto {
            livePhoto = false
            raw = false
        } else if livePhoto && raw {
            if raw != old.raw { livePhoto = false } else { raw = false }
        }
    }

    func requiresCaptureReconfiguration(comparedTo old: CameraSettings) -> Bool {
        mode != old.mode || resolution != old.resolution || captureFPS != old.captureFPS || autoFPS != old.autoFPS ||
        horizonLock != old.horizonLock || zoomLock != old.zoomLock || livePhoto != old.livePhoto || raw != old.raw ||
        mirrorSelfie != old.mirrorSelfie || isProcessedPhoto != old.isProcessedPhoto || stabilization != old.stabilization ||
        codec != old.codec || colorProfile != old.colorProfile || audioMode != old.audioMode || windNoiseRemoval != old.windNoiseRemoval ||
        responsiveCapture != old.responsiveCapture || zeroShutterLag != old.zeroShutterLag || fastCapturePrioritization != old.fastCapturePrioritization ||
        autoDeferredPhotoDelivery != old.autoDeferredPhotoDelivery || photoQuality != old.photoQuality || cinematicAperture != old.cinematicAperture
    }

    var cadence: RecordingCadence {
        switch mode {
        case .slowMotion: return .slowMotion(captureFPS: slowMotionFPS, playbackFPS: 30)
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
    var supportedResolutions: [Resolution] = [.hd, .fullHD]
    var supportedFPS: [Int] = [30]
    var supportedSlowMotionFPS: [Int] = []
    var autoFPS = false
    var responsiveCapture = false
    var zeroShutterLag = false
    var fastCapturePrioritization = false
    var autoDeferredPhotoDelivery = false
    var smoothAutofocus = false
    var focusRangeRestriction = false
    var cinematic = false
    var spatialVideo = false
    var proRes = false
    var hdrHLG = false
    var appleLog = false
    var appleLog2 = false
    var stereoAudio = false
    var spatialAudio = false
    var windNoiseRemoval = false
    var sourceDescription = "Starting camera…"
    var supports4K: Bool { supportedResolutions.contains(.ultraHD) }
    var supports60: Bool { supportedFPS.contains(60) }
    var supports120: Bool { supportedSlowMotionFPS.contains(120) || supportedFPS.contains(120) }
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
