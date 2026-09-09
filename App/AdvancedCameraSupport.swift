import AVFoundation
import Foundation

final class NativeMovieController: NSObject, AVCaptureFileOutputRecordingDelegate {
    private weak var engine: CaptureEngine?
    private var output: AVCaptureMovieFileOutput?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var settings = CameraSettings()
    private var destination: URL?
    private var completion: ((Result<MediaDraft, Error>) -> Void)?
    private var stateChanged: ((Bool) -> Void)?

    var isRecording: Bool { output?.isRecording == true }

    static func augment(_ base: CameraCapabilities, engine: CaptureEngine) -> CameraCapabilities {
        var result = base
        guard let videoInput = engine.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.ports.contains(where: { $0.mediaType == .video }) }) else { return result }
        let device = videoInput.device
        let format = device.activeFormat
        result.supportedResolutions = [.hd, .fullHD] + (base.supports4K ? [.ultraHD] : [])
        let fpsCandidates = [24, 25, 30, 50, 60, 120]
        result.supportedFPS = fpsCandidates.filter { fps in device.formats.contains { f in f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) } } }
        result.supportedSlowMotionFPS = [120, 240].filter { fps in device.formats.contains { f in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) } } }
        if #available(iOS 18.0, *) { result.autoFPS = format.isAutoVideoFrameRateSupported }
        result.smoothAutofocus = device.isSmoothAutoFocusSupported
        result.focusRangeRestriction = device.isAutoFocusRangeRestrictionSupported
        result.faceDrivenAutofocus = device.isFocusModeSupported(.continuousAutoFocus)
        var stabilizationModes: [StabilizationChoice] = [.off]
        for choice in [StabilizationChoice.standard, .cinematic, .extended] where format.isVideoStabilizationModeSupported(choice.avMode) { stabilizationModes.append(choice) }
        if format.isVideoStabilizationModeSupported(.auto) { stabilizationModes.append(.auto) }
        if #available(iOS 18.0, *), format.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced) { stabilizationModes.append(.enhanced) }
        if #available(iOS 26.0, *) {
            if format.isVideoStabilizationModeSupported(.previewOptimized) { stabilizationModes.append(.previewOptimized) }
            if format.isVideoStabilizationModeSupported(.lowLatency) { stabilizationModes.append(.lowLatency) }
        }
        result.supportedStabilizationModes = stabilizationModes
        result.hdrHLG = format.supportedColorSpaces.contains(.HLG_BT2020)
        result.appleLog = format.supportedColorSpaces.contains(.appleLog)
        if #available(iOS 26.0, *) {
            result.appleLog2 = format.supportedColorSpaces.contains(.appleLog2)
            result.cinematic = videoInput.isCinematicVideoCaptureSupported
        }
        if #available(iOS 18.0, *) { result.spatialVideo = format.isSpatialVideoCaptureSupported }
        if let photo = engine.session.outputs.compactMap({ $0 as? AVCapturePhotoOutput }).first {
            result.responsiveCapture = photo.isResponsiveCaptureSupported
            result.zeroShutterLag = photo.isZeroShutterLagSupported
            result.fastCapturePrioritization = photo.isFastCapturePrioritizationSupported
            result.autoDeferredPhotoDelivery = photo.isAutoDeferredPhotoDeliverySupported
            result.proRAW = photo.isAppleProRAWSupported
            result.depthData = photo.isDepthDataDeliverySupported
            result.portraitEffectsMatte = photo.isPortraitEffectsMatteDeliverySupported
            result.semanticMattes = !photo.availableSemanticSegmentationMatteTypes.isEmpty
            if #available(iOS 18.0, *) { result.constantColor = photo.isConstantColorSupported }
            result.autoRedEyeReduction = photo.isAutoRedEyeReductionSupported
            result.contentAwareDistortionCorrection = photo.isContentAwareDistortionCorrectionSupported
            result.virtualDeviceFusion = photo.isVirtualDeviceFusionSupported
            if #available(iOS 26.0, *) { result.sensorOrientationCompensation = photo.isCameraSensorOrientationCompensationSupported }
            result.cameraCalibrationData = photo.isCameraCalibrationDataDeliverySupported
        }
        let probe = AVCaptureMovieFileOutput()
        result.proRes = probe.availableVideoCodecTypes.contains(.proRes422) || probe.availableVideoCodecTypes.contains(.proRes422LT) || probe.availableVideoCodecTypes.contains(.proRes422HQ)
        if #available(iOS 26.0, *), let audioInput = engine.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.ports.contains(where: { $0.mediaType == .audio }) }) {
            result.stereoAudio = audioInput.isMultichannelAudioModeSupported(.stereo)
            result.spatialAudio = audioInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
            result.windNoiseRemoval = audioInput.isWindNoiseRemovalSupported
        }
        return result
    }

    static func applyLiveSettings(_ settings: CameraSettings, engine: CaptureEngine) {
        engine.sessionQueue.async {
            guard let videoInput = engine.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.ports.contains(where: { $0.mediaType == .video }) }) else { return }
            let device = videoInput.device
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = settings.smoothAutofocus }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
                    device.isFaceDrivenAutoFocusEnabled = settings.faceDrivenAutofocus
                }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = settings.focusRange.avValue }
                if #available(iOS 18.0, *), device.activeFormat.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = settings.autoFPS }
                let desiredColor: AVCaptureColorSpace
                switch settings.colorProfile {
                case .sdr: desiredColor = .sRGB
                case .hdrHLG: desiredColor = .HLG_BT2020
                case .appleLog: desiredColor = .appleLog
                case .appleLog2:
                    if #available(iOS 26.0, *) { desiredColor = .appleLog2 } else { desiredColor = .appleLog }
                }
                if device.activeFormat.supportedColorSpaces.contains(desiredColor) { device.activeColorSpace = desiredColor }
                device.automaticallyAdjustsVideoHDREnabled = false
                if device.activeFormat.isVideoHDRSupported { device.isVideoHDREnabled = settings.colorProfile == .hdrHLG }
            } catch { }
            if let photo = engine.session.outputs.compactMap({ $0 as? AVCapturePhotoOutput }).first {
                engine.session.beginConfiguration()
                if photo.isResponsiveCaptureSupported { photo.isResponsiveCaptureEnabled = settings.responsiveCapture }
                if photo.isZeroShutterLagSupported { photo.isZeroShutterLagEnabled = settings.zeroShutterLag }
                if photo.isFastCapturePrioritizationSupported { photo.isFastCapturePrioritizationEnabled = settings.fastCapturePrioritization }
                if photo.isAutoDeferredPhotoDeliverySupported { photo.isAutoDeferredPhotoDeliveryEnabled = settings.autoDeferredPhotoDelivery }
                if photo.isDepthDataDeliverySupported { photo.isDepthDataDeliveryEnabled = settings.depthData }
                if photo.isPortraitEffectsMatteDeliverySupported { photo.isPortraitEffectsMatteDeliveryEnabled = settings.portraitEffectsMatte && settings.depthData }
                photo.enabledSemanticSegmentationMatteTypes = settings.semanticMattes ? photo.availableSemanticSegmentationMatteTypes : []
                if #available(iOS 18.0, *), photo.isConstantColorSupported { photo.isConstantColorEnabled = settings.constantColor }
                if #available(iOS 26.0, *), photo.isCameraSensorOrientationCompensationSupported { photo.isCameraSensorOrientationCompensationEnabled = settings.sensorOrientationCompensation && !settings.raw }
                if photo.isContentAwareDistortionCorrectionSupported { photo.isContentAwareDistortionCorrectionEnabled = settings.contentAwareDistortionCorrection && !settings.cameraCalibrationData }
                if photo.isAppleProRAWSupported { photo.isAppleProRAWEnabled = settings.raw && settings.preferProRAW }
                photo.maxPhotoQualityPrioritization = settings.photoQuality.avValue
                engine.session.commitConfiguration()
            }
            for connection in engine.session.outputs.compactMap({ $0.connection(with: .video) }) where connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = settings.horizonLock || settings.zoomLock ? .off : settings.stabilization.avMode
            }
            if #available(iOS 26.0, *), let audioInput = engine.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.ports.contains(where: { $0.mediaType == .audio }) }) {
                let requested: AVCaptureMultichannelAudioMode = settings.audioMode == .spatial ? .firstOrderAmbisonics : (settings.audioMode == .stereo ? .stereo : .none)
                if audioInput.isMultichannelAudioModeSupported(requested) { audioInput.multichannelAudioMode = requested }
                if audioInput.isWindNoiseRemovalSupported { audioInput.isWindNoiseRemovalEnabled = settings.windNoiseRemoval }
            }
        }
    }

    func start(engine: CaptureEngine, settings: CameraSettings, stateChanged: @escaping (Bool) -> Void, completion: @escaping (Result<MediaDraft, Error>) -> Void) {
        engine.sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.output?.isRecording != true else { return }
            do {
                try MediaFiles.requireSpace()
                let session = engine.session
                guard let videoInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.ports.contains(where: { $0.mediaType == .video }) }) else { throw CameraFailure.message("No active video input is available.") }
                session.beginConfiguration()
                var movie = session.outputs.compactMap({ $0 as? AVCaptureMovieFileOutput }).first
                if movie == nil {
                    let candidate = AVCaptureMovieFileOutput()
                    guard session.canAddOutput(candidate) else { session.commitConfiguration(); throw CameraFailure.message("This camera configuration cannot add native movie recording.") }
                    session.addOutput(candidate)
                    movie = candidate
                }
                guard let movie else { session.commitConfiguration(); throw CameraFailure.message("Native movie output is unavailable.") }
                var metadata = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first
                if settings.mode == .cinematic && metadata == nil {
                    let candidate = AVCaptureMetadataOutput()
                    if session.canAddOutput(candidate) { session.addOutput(candidate); metadata = candidate }
                }
                if #available(iOS 26.0, *) {
                    if settings.mode == .cinematic {
                        guard videoInput.isCinematicVideoCaptureSupported, let metadata else { session.commitConfiguration(); throw CameraFailure.message("Cinematic Video is not supported by this lens/format.") }
                        videoInput.isCinematicVideoCaptureEnabled = true
                        metadata.metadataObjectTypes = metadata.requiredMetadataObjectTypesForCinematicVideoCapture
                        let f = videoInput.device.activeFormat
                        if f.minSimulatedAperture > 0 {
                            videoInput.simulatedAperture = min(max(settings.cinematicAperture, f.minSimulatedAperture), f.maxSimulatedAperture)
                        }
                    } else if videoInput.isCinematicVideoCaptureEnabled {
                        videoInput.isCinematicVideoCaptureEnabled = false
                        metadata?.metadataObjectTypes = []
                    }
                }
                if #available(iOS 18.0, *) {
                    if settings.mode == .spatial {
                        guard movie.isSpatialVideoCaptureSupported else { session.commitConfiguration(); throw CameraFailure.message("Spatial Video is not supported by this lens/format.") }
                        movie.isSpatialVideoCaptureEnabled = true
                    } else if movie.isSpatialVideoCaptureSupported { movie.isSpatialVideoCaptureEnabled = false }
                }
                session.commitConfiguration()

                if let connection = movie.connection(with: .video) {
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = settings.stabilization.avMode }
                    let rotation: CGFloat = settings.videoFraming == .portrait ? 90 : 0
                    if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
                    movie.setRecordsVideoOrientationAndMirroringChangesAsMetadataTrack(true, for: connection)
                    if settings.mode != .spatial && movie.availableVideoCodecTypes.contains(settings.codec.avCodec) {
                        movie.setOutputSettings([AVVideoCodecKey: settings.codec.avCodec], for: connection)
                    }
                }
                movie.metadata = Self.movieMetadata(settings)
                self.engine = engine
                self.output = movie
                self.metadataOutput = metadata
                self.settings = settings
                self.stateChanged = stateChanged
                self.completion = completion
                let url = try MediaFiles.newURL(extension: "mov")
                self.destination = url
                movie.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { stateChanged(true) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop() { output?.stopRecording() }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let completion = self.completion
        let stateChanged = self.stateChanged
        self.completion = nil
        self.stateChanged = nil
        DispatchQueue.main.async { stateChanged?(false) }
        if let error {
            try? FileManager.default.removeItem(at: outputFileURL)
            DispatchQueue.main.async { completion?(.failure(error)) }
        } else {
            let summary = "Native \(settings.mode.rawValue) · \(settings.codec.rawValue) · \(settings.colorProfile.rawValue) · \(settings.audioMode.rawValue)"
            DispatchQueue.main.async { completion?(.success(MediaDraft(url: outputFileURL, isVideo: true, summary: summary))) }
        }
    }

    static func movieMetadata(_ settings: CameraSettings) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func append(_ id: AVMetadataIdentifier, _ value: String) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            items.append(item)
        }
        append(.quickTimeMetadataTitle, settings.metadataTitle)
        append(.quickTimeMetadataAuthor, settings.metadataAuthor)
        append(.quickTimeMetadataCopyright, settings.metadataCopyright)
        append(.quickTimeMetadataDescription, settings.metadataDescription)
        append(.quickTimeMetadataKeywords, settings.metadataKeywords)
        let software = AVMutableMetadataItem()
        software.identifier = .quickTimeMetadataSoftware
        software.value = "HorizonCamera" as NSString
        items.append(software)
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = ISO8601DateFormatter().string(from: Date()) as NSString
        items.append(date)
        return items
    }
}
