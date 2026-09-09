import Foundation
import AVFoundation

public enum CameraMode: String, CaseIterable, Codable, Identifiable {
    case timeLapse = "TIME-LAPSE", slowMotion = "SLO-MO", action = "ACTION", cinematic = "CINEMATIC", video = "VIDEO", dualCapture = "DUAL", photo = "PHOTO", portrait = "PORTRAIT", panorama = "PANO", spatialPhoto = "SPATIAL PHOTO", spatial = "SPATIAL VIDEO"
    public var id: String { rawValue }
    var isPhotoMode: Bool { self == .photo || self == .portrait || self == .panorama || self == .spatialPhoto }
    var isMovie: Bool { !isPhotoMode }
    var isNativeMovieMode: Bool { self == .cinematic || self == .spatial }
    var isStandaloneCaptureMode: Bool { self == .panorama || self == .spatialPhoto || self == .dualCapture }
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

enum PhotographicStyleApprox: String, CaseIterable, Codable, Identifiable {
    case standard = "Standard", vibrant = "Vibrant", richContrast = "Rich Contrast", warm = "Warm", cool = "Cool", roseGold = "Rose Gold", muted = "Muted"
    var id: String { rawValue }
}

enum ComputationalPhotoMode: String, CaseIterable, Codable, Identifiable {
    case off = "Off", autoHDR = "Smart HDR-like", night = "Night-like", detailFusion = "Detail Fusion"
    var id: String { rawValue }
    var isBracketed: Bool { self != .off }
    var exposureBiases: [Float] {
        switch self {
        case .off: return []
        case .autoHDR: return [-2, 0, 2]
        case .night: return [-0.7, -0.35, 0, 0.35, 0.7]
        case .detailFusion: return [-0.35, 0, 0.35]
        }
    }
}

enum PortraitLightingApprox: String, CaseIterable, Codable, Identifiable {
    case natural = "Natural", studio = "Studio", contour = "Contour", stage = "Stage", stageMono = "Stage Mono", highKeyMono = "High-Key Mono"
    var id: String { rawValue }
}

enum DualCaptureLayout: String, CaseIterable, Codable, Identifiable {
    case pictureInPicture = "Picture in Picture", splitVertical = "Split Vertical", splitHorizontal = "Split Horizontal"
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
    case sdr = "SDR / Rec.709", hdrHLG = "HDR / HLG", dolbyVision84 = "Dolby Vision 8.4 / HLG", appleLog = "Apple Log", appleLog2 = "Apple Log 2"
    var id: String { rawValue }
    var isLog: Bool { self == .appleLog || self == .appleLog2 }
    var isHDR: Bool { self == .hdrHLG || self == .dolbyVision84 }
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
    var lockCameraSwitching = false
    var centerStage = false
    var smartFraming = false
    var lensCleaningHints = true
    var horizonLock = true
    var zoomLock = false
    var zoom = 1.0
    var grid = true
    var showLevel = true
    var showOverview = true
    var scanQRCodes = true
    var showDetectedText = true
    var mirrorSelfie = true
    var photographicStyle: PhotographicStyleApprox = .standard
    var styleIntensity = 1.0
    var styleTone = 0.0
    var styleWarmth = 0.0
    var computationalPhoto: ComputationalPhotoMode = .off
    var portraitLighting: PortraitLightingApprox = .natural
    var portraitBlurRadius = 14.0
    var actionStrength = 0.75
    var panoramaFeather = 0.55
    var dualCaptureLayout: DualCaptureLayout = .pictureInPicture
    var flash: FlashChoice = .off
    var torch = false
    var livePhoto = false
    var raw = false
    var preferProRAW = true
    var photoResolutionMP = 0
    var depthData = false
    var depthDataFiltered = true
    var portraitEffectsMatte = false
    var semanticMattes = false
    var constantColor = false
    var constantColorFallback = true
    var autoRedEyeReduction = true
    var contentAwareDistortionCorrection = true
    var virtualDeviceFusion = true
    var sensorOrientationCompensation = true
    var cameraCalibrationData = false
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
    var metadataTitle = ""
    var metadataAuthor = ""
    var metadataCopyright = ""
    var metadataDescription = ""
    var metadataKeywords = ""
    var includeLocationMetadata = false
    var horizonTrimDegrees = 0.0
    var motionOffsetMilliseconds = 0.0

    var framing: Framing { mode.isPhotoMode ? photoFraming : videoFraming }
    var hasCustomStyle: Bool { photographicStyle != .standard || abs(styleTone) > 0.001 || abs(styleWarmth) > 0.001 }
    var isProcessedPhoto: Bool { mode.isPhotoMode && mode != .panorama && mode != .spatialPhoto && (mode == .portrait || horizonLock || zoomLock || zoom > 1.001 || filter != .original || photoFraming != .classic || hasCustomStyle || portraitLighting != .natural || computationalPhoto != .off) }
    var captureFPS: Int { mode == .slowMotion ? slowMotionFPS : fps }
    var outputSize: Size2 { framing.size(longEdge: mode == .slowMotion ? min(1920, resolution.longEdge) : resolution.longEdge) }
    var reserve: Double { mode == .action ? max(0.58, 0.86 - actionStrength * 0.22) : (zoomLock ? 0.80 : (horizonLock ? 0.97 : 1)) }
    var usesNativeMoviePipeline: Bool { mode.isNativeMovieMode || codec.isProRes || colorProfile != .sdr || audioMode != .mono }
    var usesBracketedPhotoPipeline: Bool { mode == .photo && computationalPhoto.isBracketed }

    mutating func normalize(changedFrom old: CameraSettings) {
        zoom = min(max(zoom, 1), 12)
        styleIntensity = min(max(styleIntensity, 0), 1)
        styleTone = min(max(styleTone, -1), 1)
        styleWarmth = min(max(styleWarmth, -1), 1)
        portraitBlurRadius = min(max(portraitBlurRadius, 0), 40)
        actionStrength = min(max(actionStrength, 0), 1)
        panoramaFeather = min(max(panoramaFeather, 0.1), 0.9)
        if mode.isPhotoMode {
            if codec.isProRes { codec = .efficient }
            colorProfile = .sdr
            audioMode = .mono
        }
        if mode == .action {
            horizonLock = true
            zoomLock = false
            stabilization = .off
            codec = .efficient
            colorProfile = .sdr
            photographicStyle = .standard
            filter = .original
        }
        if mode == .panorama || mode == .spatialPhoto {
            horizonLock = false
            zoomLock = false
            raw = false
            livePhoto = false
            constantColor = false
            computationalPhoto = .off
            filter = .original
            photographicStyle = .standard
            photoFraming = .classic
        }
        if mode == .dualCapture {
            horizonLock = false
            zoomLock = false
            fps = 30
            if resolution == .ultraHD { resolution = .fullHD }
            codec = .efficient
            colorProfile = .sdr
            audioMode = .mono
            photographicStyle = .standard
            filter = .original
        }
        if computationalPhoto != .off {
            raw = false
            livePhoto = false
            depthData = false
            portraitEffectsMatte = false
            semanticMattes = false
            constantColor = false
            flash = .off
        }
        if mode == .portrait {
            centerStage = false
            smartFraming = false
            depthData = true
            portraitEffectsMatte = true
            horizonLock = false
            zoomLock = false
            filter = .original
            raw = false
            livePhoto = false
            photoFraming = .classic
        }
        if constantColor {
            raw = false
            livePhoto = false
            if flash == .off { flash = .auto }
        }
        if raw {
            centerStage = false
            depthData = false
            portraitEffectsMatte = false
            semanticMattes = false
            constantColor = false
            cameraCalibrationData = false
        }
        if !depthData { portraitEffectsMatte = false }
        if !raw { preferProRAW = true }
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
        if colorProfile == .dolbyVision84 { codec = .efficient }
        if mode.isNativeMovieMode || (mode.isMovie && usesNativeMoviePipeline) {
            if videoFraming == .square || videoFraming == .classic { videoFraming = .portrait }
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
        autoDeferredPhotoDelivery != old.autoDeferredPhotoDelivery || photoQuality != old.photoQuality ||
        depthData != old.depthData || portraitEffectsMatte != old.portraitEffectsMatte || semanticMattes != old.semanticMattes ||
        constantColor != old.constantColor || contentAwareDistortionCorrection != old.contentAwareDistortionCorrection ||
        sensorOrientationCompensation != old.sensorOrientationCompensation || cameraCalibrationData != old.cameraCalibrationData ||
        cinematicAperture != old.cinematicAperture || computationalPhoto != old.computationalPhoto || actionStrength != old.actionStrength
    }

    var cadence: RecordingCadence {
        switch mode {
        case .slowMotion: return .slowMotion(captureFPS: Double(slowMotionFPS), playbackFPS: 30)
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
    let isVirtual: Bool
}

struct CameraCapabilities {
    var lenses: [LensOption] = []
    var selectedLens = ""
    var flash = false
    var torch = false
    var livePhoto = false
    var raw = false
    var proRAW = false
    var depthData = false
    var portraitEffectsMatte = false
    var semanticMattes = false
    var constantColor = false
    var autoRedEyeReduction = false
    var contentAwareDistortionCorrection = false
    var virtualDeviceFusion = false
    var sensorOrientationCompensation = false
    var cameraCalibrationData = false
    var manualFocus = false
    var maxISO: Float = 1600
    var minISO: Float = 25
    var minEV: Float = -2
    var maxEV: Float = 2
    var supportedResolutions: [Resolution] = [.hd, .fullHD]
    var supportedFPS: [Int] = [30]
    var supportedSlowMotionFPS: [Int] = []
    var supportedPhotoResolutionsMP: [Int] = []
    var autoFPS = false
    var lockCameraSwitching = false
    var centerStage = false
    var smartFraming = false
    var lensSmudgeDetection = false
    var qrScanning = false
    var liveText = true
    var bracketedCapture = false
    var maxBracketedCaptureCount = 0
    var multiCam = false
    var spatialPhoto = false
    var responsiveCapture = false
    var zeroShutterLag = false
    var fastCapturePrioritization = false
    var autoDeferredPhotoDelivery = false
    var smoothAutofocus = false
    var faceDrivenAutofocus = false
    var focusRangeRestriction = false
    var cinematic = false
    var spatialVideo = false
    var proRes = false
    var hdrHLG = false
    var dolbyVision = false
    var appleLog = false
    var appleLog2 = false
    var stereoAudio = false
    var spatialAudio = false
    var windNoiseRemoval = false
    var supportedStabilizationModes: [StabilizationChoice] = [.off]
    var sourceDescription = "Starting camera…"
    var supports4K = false
    var supports60 = false
    var supports120 = false
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
    var lensStatus = "Off"
    var smartFramingStatus = "Off"
}

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
