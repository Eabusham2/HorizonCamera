import AVFoundation
import Foundation

/// Validate the requested resources before invoking AVFoundation, which raises
/// Objective-C exceptions for some unsupported capture combinations.
struct PhotoCapturePlan {
    let codec: AVVideoCodecType
    let rawPixelFormat: OSType?
    let livePhoto: Bool
    let qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization

    init(settings: CameraSettings, availableCodecs: [AVVideoCodecType], rawFormats: [OSType],
         livePhotoEnabled: Bool, livePhotoSuspended: Bool,
         isAppleProRAW: (OSType) -> Bool = AVCapturePhotoOutput.isAppleProRAWPixelFormat,
         isBayerRAW: (OSType) -> Bool = AVCapturePhotoOutput.isBayerRAWPixelFormat) throws {
        codec = settings.codec == .efficient ? .hevc : .jpeg
        guard availableCodecs.contains(codec) else {
            throw CameraFailure.message("The selected photo encoding is unavailable on this lens. Choose another photo format.")
        }
        if settings.raw || settings.livePhoto {
            guard settings.mode == .photo, !(settings.raw && settings.livePhoto) else {
                throw CameraFailure.message("Choose RAW or Live Photo in Photo mode before capturing.")
            }
        }
        if settings.raw {
            guard let format = rawFormats.first(where: { settings.preferProRAW ? isAppleProRAW($0) : isBayerRAW($0) }) else {
                let name = settings.preferProRAW ? "Apple ProRAW" : "Bayer RAW"
                throw CameraFailure.message("\(name) is unavailable on this lens or format. Choose a supported RAW type or turn RAW off.")
            }
            rawPixelFormat = format
        } else { rawPixelFormat = nil }
        if settings.livePhoto && (!livePhotoEnabled || livePhotoSuspended) {
            throw CameraFailure.message("Live Photo is unavailable or temporarily suspended. Wait, choose another lens, or turn Live Photo off.")
        }
        livePhoto = settings.livePhoto
        // Bayer capture requires .speed; ProRAW supports the requested quality policy.
        qualityPrioritization = settings.raw && !settings.preferProRAW ? .speed : settings.photoQuality.avValue
    }
}

struct PhotoPacket {
    let data: Data
    let rawData: Data?
    let liveMovie: URL?
    let timestamp: CMTime
    let settings: CameraSettings
    let hasDepthData: Bool
    let hasPortraitEffectsMatte: Bool
    let hasCalibrationData: Bool
    let depthData: AVDepthData?
    let portraitEffectsMatte: AVPortraitEffectsMatte?

    // The received resources also guard against stale or unnormalized settings.
    var requiresProcessing: Bool {
        settings.isProcessedPhoto && !settings.raw && !settings.livePhoto && rawData == nil && liveMovie == nil
    }

    func validate() throws {
        guard !data.isEmpty else { throw CameraFailure.message("The photo did not finish processing.") }
        if settings.raw && rawData == nil {
            throw CameraFailure.message("The camera did not return the requested RAW original. No ordinary-photo substitute was saved.")
        }
        if let rawData, rawData.isEmpty {
            throw CameraFailure.message("The camera returned an empty RAW original.")
        }
        if settings.livePhoto && liveMovie == nil {
            throw CameraFailure.message("The Live Photo movie did not finish. No still-only substitute was saved.")
        }
        if let liveMovie {
            let values = try liveMovie.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw CameraFailure.message("The Live Photo movie is missing or empty.")
            }
        }
    }
}
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let id: Int64
    private let settings: CameraSettings
    private let liveURL: URL?
    private let completion: (Result<PhotoPacket, Error>) -> Void
    private let lock = NSLock()
    private var imageData: Data?
    private var rawData: Data?
    private var completedLiveMovie: URL?
    private var timestamp: CMTime = .invalid
    private var hasDepthData = false
    private var hasPortraitEffectsMatte = false
    private var hasCalibrationData = false
    private var depthData: AVDepthData?
    private var portraitEffectsMatte: AVPortraitEffectsMatte?
    private var error: Error?
    init(id: Int64, settings: CameraSettings, liveURL: URL?, completion: @escaping (Result<PhotoPacket, Error>) -> Void) {
        self.id = id; self.settings = settings; self.liveURL = liveURL; self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { self.error = error; return }
        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            self.error = CameraFailure.message("The camera returned an empty photo."); return
        }
        if photo.isRawPhoto { rawData = data } else {
            imageData = data; timestamp = photo.timestamp
            depthData = photo.depthData
            portraitEffectsMatte = photo.portraitEffectsMatte
            hasDepthData = depthData != nil
            hasPortraitEffectsMatte = portraitEffectsMatte != nil
            hasCalibrationData = photo.cameraCalibrationData != nil
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { self.error = error; return }
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            self.error = CameraFailure.message("The Live Photo movie is incomplete."); return
        }
        completedLiveMovie = outputFileURL
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let failure = error ?? self.error
        let data = imageData, raw = rawData, time = timestamp, movie = completedLiveMovie
        let depth = hasDepthData, matte = hasPortraitEffectsMatte, calibration = hasCalibrationData
        let capturedDepth = depthData, capturedMatte = portraitEffectsMatte
        lock.unlock()
        do {
            if let failure { throw failure }
            guard let data else { throw CameraFailure.message("The photo did not finish processing.") }
            let packet = PhotoPacket(data: data, rawData: raw, liveMovie: movie, timestamp: time, settings: settings,
                hasDepthData: depth, hasPortraitEffectsMatte: matte, hasCalibrationData: calibration,
                depthData: capturedDepth, portraitEffectsMatte: capturedMatte)
            try packet.validate()
            completion(.success(packet))
        } catch {
            for url in Set([liveURL, movie].compactMap({ $0 })) { try? FileManager.default.removeItem(at: url) }
            completion(.failure(error))
        }
    }
}
