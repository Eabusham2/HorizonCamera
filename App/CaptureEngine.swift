import Foundation
import AVFoundation
import CoreImage
import UIKit

public enum CaptureState: String { case stopped, starting, ready, recording, finishing, takingPhoto }

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    let frameQueue = DispatchQueue(label: "camera.frames", qos: .userInteractive)
    let renderer: ImageRenderer
    let processor: FrameProcessor
    let motion = MotionService()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let textDetector = LiveTextDetector()
    private let textQueue = DispatchQueue(label:"camera.live-text",qos:.utility)
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var devices: [AVCaptureDevice] = []
    private var configuration = CameraSettings()
    private var state: CaptureState = .stopped // sessionQueue only
    private var wantedRunning = false
    private var microphoneAllowed = false
    private var configured = false
    private var reportedCapabilities = CameraCapabilities()
    private var photoJobs: [Int64: PhotoCapture] = [:]
    private var bracketJobs: [Int64: BracketPhotoCapture] = [:]
    private var notifications: [NSObjectProtocol] = []
    private var movie: MovieRecorder? // frameQueue only
    private var panorama: PanoramaAssembler? // frameQueue only
    private var lastDiagnosticsTime = 0.0
    private var lastSpaceCheck = 0.0
    private var lastTextTime = 0.0
    private var lastSmartFramingTime = 0.0
    var onState: ((CaptureState) -> Void)?
    var onCapabilities: ((CameraCapabilities, CameraSettings) -> Void)?
    var onDiagnostics: ((FrameDiagnostics) -> Void)?
    var onMedia: ((Result<MediaDraft, Error>) -> Void)?
    var onCode: ((String) -> Void)?
    var onText: (([String]) -> Void)?
    var onError: ((String) -> Void)?

    init(renderer: ImageRenderer) {
        self.renderer = renderer; processor = FrameProcessor(motion: motion, renderer: renderer)
        super.init()
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.stopRecordingLocked()
                self.report("Camera interrupted by another app or a system event. Any recording is being finalized.")
            }
        })
        notifications.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.wantedRunning else { return }
                if !self.session.isRunning { self.session.startRunning() }
                if self.state != .recording && self.state != .finishing { self.setState(.ready) }
            }
        })
        notifications.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.stopRecordingLocked()
                self.report(error?.localizedDescription ?? "The camera session stopped unexpectedly.")
                if error?.code == .mediaServicesWereReset, self.wantedRunning, self.state != .finishing {
                    self.session.startRunning(); self.setState(.ready)
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.stopRecording()
        })
        notifications.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            if ProcessInfo.processInfo.thermalState == .critical {
                self?.suspend()
                self?.report("The iPhone is too hot. Recording was stopped; let it cool before resuming.")
            }
        })
    }
    deinit { notifications.forEach { NotificationCenter.default.removeObserver($0) }; motion.stop() }
    private func setState(_ next: CaptureState) {
        state = next; DispatchQueue.main.async { [weak self] in self?.onState?(next) }
    }
    private func report(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onError?(message) } }
    private func deliver(_ result: Result<MediaDraft, Error>) {
        DispatchQueue.main.async { [weak self] in self?.onMedia?(result) }
    }
    func start(settings: CameraSettings, microphoneAllowed: Bool) {
        sessionQueue.async { [self] in
            wantedRunning = true; self.microphoneAllowed = microphoneAllowed
            guard state != .recording && state != .finishing && state != .takingPhoto else { return }
            setState(.starting)
            do {
                if microphoneAllowed {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
                    try audio.setActive(true)
                }
                try configure(settings, selected: videoInput?.device.uniqueID)
                motion.start()
                if !session.isRunning { session.startRunning() }
                guard session.isRunning else { throw CameraFailure.message("The camera could not start. Check permission and close other camera apps.") }
                setState(.ready)
            } catch { setState(.stopped); report(error.localizedDescription) }
        }
    }
    func suspend() {
        sessionQueue.async { [self] in
            wantedRunning = false
            stopRecordingLocked()
            if session.isRunning { session.stopRunning() }
            motion.stop()
            if microphoneAllowed { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            if state != .finishing && state != .takingPhoto { setState(.stopped) }
            frameQueue.async { [self] in processor.preview.publish(nil) }
        }
    }

    func pauseForExternalCapture(_ completion: @escaping () -> Void) {
        sessionQueue.async { [self] in
            wantedRunning = false
            if state == .recording { stopRecordingLocked() }
            if session.isRunning { session.stopRunning() }
            motion.stop()
            if microphoneAllowed { try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation) }
            if state != .finishing && state != .takingPhoto { setState(.stopped) }
            frameQueue.async { [self] in processor.preview.publish(nil) }
            DispatchQueue.main.async { completion() }
        }
    }
    func update(_ settings: CameraSettings, lensID: String? = nil) {
        sessionQueue.async { [self] in
            guard state == .ready || state == .stopped else { return }
            let old = configuration, previousLens = videoInput?.device.uniqueID
            if configured && settings == old && (lensID == nil || lensID == previousLens) { return }
            do {
                if configured, let device = videoInput?.device,
                   (lensID == nil || lensID == previousLens),
                   !settings.requiresCaptureReconfiguration(comparedTo: old) {
                    try applyControls(settings, device: device)
                    configuration = settings
                    frameQueue.sync { [self] in processor.configure(settings, front: device.position == .front) }
                    let capabilities = reportedCapabilities
                    DispatchQueue.main.async { [weak self] in self?.onCapabilities?(capabilities, settings) }
                    return
                }
                try configure(settings, selected: lensID ?? previousLens)
            } catch {
                report(error.localizedDescription)
                do { try configure(old, selected: previousLens) }
                catch { report("The camera could not restore its previous configuration: \(error.localizedDescription)") }
            }
        }
    }
    private func discover() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified).devices
    }
    private func configure(_ settings: CameraSettings, selected id: String?) throws {
        if devices.isEmpty { discover() }
        guard let device = devices.first(where: { $0.uniqueID == id }) ??
                devices.first(where: { $0.position == .back && $0.isVirtualDevice }) ??
                devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw CameraFailure.message("No camera is available. A physical iPhone is required to capture.")
        }
        let previousDeviceID = videoInput?.device.uniqueID
        let fps = settings.captureFPS
        let targetWidth = settings.mode.isPhotoMode ? 1920 : settings.resolution.longEdge
        func maxPhotoArea(_ format: AVCaptureDevice.Format) -> Int64 {
            format.supportedMaxPhotoDimensions.map { Int64($0.width)*Int64($0.height) }.max() ?? 0
        }
        let eligible = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= 1280 && d.height >= 720 &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
        }
        let sorted = eligible.sorted { a,b in
            if settings.mode.isPhotoMode {
                let ap = maxPhotoArea(a), bp = maxPhotoArea(b)
                if ap != bp { return ap > bp }
            }
            func score(_ f: AVCaptureDevice.Format) -> Double {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return abs(Double(d.width)-Double(targetWidth))*2 + abs(Double(d.height)-Double(targetWidth)*9/16)
            }
            return score(a) < score(b)
        }
        guard let format = sorted.first else { throw CameraFailure.message("This lens does not support \(fps) fps. Choose another lens or a lower frame rate.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        if !settings.mode.isPhotoMode && settings.resolution == .ultraHD && settings.mode != .slowMotion && dimensions.width < 3840 {
            throw CameraFailure.message("4K at this frame rate is not supported by this lens.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        do {
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresApplicationAudioSession = false
            if videoInput?.device.uniqueID != device.uniqueID {
                if let old = videoInput { session.removeInput(old) }
                guard session.canAddInput(input) else {
                    if let old = videoInput, session.canAddInput(old) { session.addInput(old) }
                    throw CameraFailure.message("Could not switch to this camera.")
                }
                session.addInput(input); videoInput = input
            }
            if !configured {
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
                guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else {
                    throw CameraFailure.message("This camera cannot provide photo and video output.")
                }
                session.addOutput(videoOutput); session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: frameQueue)
                }
                configured = true
            }
            if microphoneAllowed && audioInput == nil, let microphone = AVCaptureDevice.default(for: .audio) {
                let mic = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(mic) {
                    session.addInput(mic); audioInput = mic
                    if session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput); audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
                    }
                }
            }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.automaticallyAdjustsVideoHDREnabled = false
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.isSubjectAreaChangeMonitoringEnabled = !settings.aeafLock
            device.unlockForConfiguration()
            if let max = format.supportedMaxPhotoDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) {
                photoOutput.maxPhotoDimensions = max
            }
            for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = connection === photoOutput.connection(with: .video) &&
                        device.position == .front && settings.mirrorSelfie && !settings.isProcessedPhoto
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = NativeMovieController.preferredStabilization(settings,format:format)
                }
            }
            if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = settings.depthData && !settings.raw }
            if photoOutput.isPortraitEffectsMatteDeliverySupported { photoOutput.isPortraitEffectsMatteDeliveryEnabled = settings.portraitEffectsMatte && settings.depthData && !settings.raw }
            photoOutput.enabledSemanticSegmentationMatteTypes = settings.semanticMattes && !settings.raw ? photoOutput.availableSemanticSegmentationMatteTypes : []
            if #available(iOS 18.0, *), photoOutput.isConstantColorSupported { photoOutput.isConstantColorEnabled = settings.constantColor && !settings.raw }
            if #available(iOS 26.0, *), photoOutput.isCameraSensorOrientationCompensationSupported { photoOutput.isCameraSensorOrientationCompensationEnabled = settings.sensorOrientationCompensation && !settings.raw }
            if photoOutput.isContentAwareDistortionCorrectionSupported { photoOutput.isContentAwareDistortionCorrectionEnabled = settings.contentAwareDistortionCorrection && !settings.cameraCalibrationData }
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported &&
                settings.mode.isPhotoMode && settings.livePhoto && !settings.raw && !settings.isProcessedPhoto
            if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = settings.raw && settings.preferProRAW && !settings.livePhoto && !settings.isProcessedPhoto }
            if session.outputs.contains(where: { $0 === metadataOutput }) {
                metadataOutput.metadataObjectTypes = settings.scanQRCodes && metadataOutput.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            }
            session.commitConfiguration()
        } catch { session.commitConfiguration(); throw error }
        try applyControls(settings, device: device)
        let changedSource = configuration.captureFPS != settings.captureFPS || configuration.resolution != settings.resolution ||
            configuration.horizonLock != settings.horizonLock || configuration.zoomLock != settings.zoomLock ||
            configuration.actionStabilization != settings.actionStabilization || previousDeviceID != device.uniqueID
        configuration = settings
        frameQueue.sync { [self] in
            if changedSource { processor.resetGeometry() }
            processor.configure(settings, front: device.position == .front)
        }
        var capabilities = CameraCapabilities()
        let wideFOV = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })?.activeFormat.videoFieldOfView ?? 70
        capabilities.lenses = devices.map { camera in
            let front = camera.position == .front
            let factor = tan(Double(wideFOV) * .pi/360)/tan(Double(camera.activeFormat.videoFieldOfView) * .pi/360)
            let label = front ? "Front" : (camera.isVirtualDevice ? "Auto" : (abs(factor-factor.rounded()) < 0.12 ? String(format:"%.0f×",factor) : String(format:"%.1f×",factor)))
            return LensOption(id:camera.uniqueID,label:label,name:camera.localizedName,isFront:front,isVirtual:camera.isVirtualDevice)
        }.sorted {
            if $0.isFront != $1.isFront { return !$0.isFront }
            if $0.isVirtual != $1.isVirtual { return $0.isVirtual }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        capabilities.selectedLens = device.uniqueID
        capabilities.flash = device.hasFlash; capabilities.torch = device.hasTorch
        capabilities.livePhoto = photoOutput.isLivePhotoCaptureSupported
        capabilities.raw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        capabilities.qrScanning = metadataOutput.availableMetadataObjectTypes.contains(.qr)
        capabilities.maxBracketedCaptureCount = photoOutput.maxBracketedCapturePhotoCount
        capabilities.bracketedCapture = photoOutput.maxBracketedCapturePhotoCount >= 2
        capabilities.multiCam = AVCaptureMultiCamSession.isMultiCamSupported
        capabilities.spatialPhoto = AVCaptureMultiCamSession.isMultiCamSupported && devices.filter { $0.position == .back && !$0.isVirtualDevice }.count >= 2
        capabilities.manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        capabilities.maxISO = format.maxISO; capabilities.minISO = format.minISO
        capabilities.minEV = device.minExposureTargetBias; capabilities.maxEV = device.maxExposureTargetBias
        capabilities.supports4K = device.formats.contains { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 3840 }
        capabilities.supports60 = device.formats.contains { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 } }
        capabilities.supports120 = device.formats.contains { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 } }
        if settings.mode.isPhotoMode, let still = format.supportedMaxPhotoDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) {
            capabilities.sourceDescription = "\(dimensions.width)×\(dimensions.height) preview · still up to \(still.width)×\(still.height)"
        } else {
            capabilities.sourceDescription = "\(dimensions.width)×\(dimensions.height) sensor stream · \(fps) fps"
        }
        reportedCapabilities = capabilities
        DispatchQueue.main.async { [weak self] in self?.onCapabilities?(capabilities,settings) }
    }
    private func applyControls(_ settings: CameraSettings, device: AVCaptureDevice) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        if settings.manualFocus && device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(settings.lensPosition,0),1), completionHandler: nil)
        } else {
            let mode: AVCaptureDevice.FocusMode = settings.aeafLock ? .locked : .continuousAutoFocus
            if device.isFocusModeSupported(mode) { device.focusMode = mode }
        }
        if settings.manualExposure && device.isExposureModeSupported(.custom) {
            let minTime = device.activeFormat.minExposureDuration.seconds
            let maxTime = min(device.activeFormat.maxExposureDuration.seconds,1/Double(settings.captureFPS))
            let duration = CMTime(seconds: min(max(1/settings.shutterDenominator,minTime),maxTime), preferredTimescale: 1_000_000_000)
            device.setExposureModeCustom(duration: duration, iso: min(max(settings.iso,device.activeFormat.minISO),device.activeFormat.maxISO), completionHandler: nil)
        } else {
            let mode: AVCaptureDevice.ExposureMode = settings.aeafLock ? .locked : .continuousAutoExposure
            if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            device.setExposureTargetBias(min(max(settings.exposureEV,device.minExposureTargetBias),device.maxExposureTargetBias), completionHandler: nil)
        }
        if settings.whiteBalanceLock && device.isWhiteBalanceModeSupported(.locked) {
            var gains = device.deviceWhiteBalanceGains
            gains.redGain = min(max(gains.redGain,1),device.maxWhiteBalanceGain)
            gains.greenGain = min(max(gains.greenGain,1),device.maxWhiteBalanceGain)
            gains.blueGain = min(max(gains.blueGain,1),device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.hasTorch {
            if settings.torch && !settings.mode.isPhotoMode { try device.setTorchModeOn(level: 0.7) }
            else { device.torchMode = .off }
        }
    }
    func setZoom(_ zoom: Double, anchor: Point2? = nil) {
        let value = min(max(zoom,1),12)
        sessionQueue.async { [self] in
            configuration.zoom = value
            let native = configuration.usesNativeMoviePipeline
            if native, let device = videoInput?.device {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    let factor = min(max(CGFloat(value), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                    if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                    device.ramp(toVideoZoomFactor: factor, withRate: 8)
                } catch { report(error.localizedDescription) }
            }
            frameQueue.async { [self] in processor.setZoom(native ? 1 : value, atUIKit: native ? nil : anchor) }
        }
    }
    func tap(_ point: Point2) {
        frameQueue.async { [self] in
            if processor.settings.zoomLock { processor.selectTarget(atUIKit:point) }
            guard let devicePoint = processor.normalizedDevicePoint(atUIKit:point) else { return }
            sessionQueue.async { [self] in
                guard let device = videoInput?.device, !configuration.aeafLock,
                      state == .ready || state == .recording else { return }
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    if device.isFocusPointOfInterestSupported && !configuration.manualFocus {
                        device.focusPointOfInterest = devicePoint
                        if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                    }
                    if device.isExposurePointOfInterestSupported && !configuration.manualExposure {
                        device.exposurePointOfInterest = devicePoint
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    }
                } catch { report(error.localizedDescription) }
            }
        }
    }
    func startPanorama() {
        sessionQueue.async { [self] in
            guard state == .ready, session.isRunning, configuration.mode == .panorama, let device = videoInput?.device else { return }
            guard motion.sample(at:CMClockGetTime(CMClockGetHostTimeClock()).seconds) != nil else {
                report("Motion data is not ready. Panorama needs device motion to track the sweep."); return
            }
            do { try MediaFiles.requireSpace() }
            catch { report(error.localizedDescription); return }
            let fov = Double(device.activeFormat.videoFieldOfView), settings = configuration
            setState(.recording)
            frameQueue.async { [self] in
                panorama = PanoramaAssembler(renderer:renderer,horizontalFOVDegrees:fov,feather:settings.panoramaFeather)
            }
        }
    }

    private func stopPanoramaLocked() {
        guard state == .recording, configuration.mode == .panorama else { return }
        setState(.finishing)
        let settings = configuration
        frameQueue.async { [self] in
            guard let capture = panorama else {
                sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }; return
            }
            panorama = nil
            do {
                var image = try capture.finish()
                image = renderer.applyLook(image,settings:settings)
                guard let encoded = CaptureMetadata.encodeProcessed(image,renderer:renderer,efficient:settings.codec == .efficient,settings:settings) else {
                    throw CameraFailure.message("The panorama could not be encoded.")
                }
                let url = try MediaFiles.newURL(extension:encoded.1)
                try encoded.0.write(to:url,options:.atomic)
                deliver(.success(MediaDraft(url:url,isVideo:false,summary:"Panorama approximation · \(capture.count) motion-guided frames")))
            } catch { deliver(.failure(error)) }
            sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }
        }
    }

    func startRecording() {
        sessionQueue.async { [self] in
            guard state == .ready, session.isRunning else { return }
            do {
                try MediaFiles.requireSpace()
                let url = try MediaFiles.newURL(extension:"mov"), settings = configuration
                let microphoneAvailable = audioInput != nil && audioOutput.connection(with: .audio) != nil
                setState(.recording)
                frameQueue.async { [self] in
                    do {
                        guard processor.lastPlan != nil else { throw CameraFailure.message("Wait for the camera preview before recording.") }
                        if (settings.horizonLock || settings.actionStabilization) && motion.sample(at:CMClockGetTime(CMClockGetHostTimeClock()).seconds) == nil {
                            throw CameraFailure.message("Motion data is not ready. Enable Motion permission or turn sensor-driven stabilization off.")
                        }
                        processor.beginRecording()
                        movie = try MovieRecorder(url:url,settings:settings,renderer:renderer,microphoneAvailable:microphoneAvailable)
                        lastSpaceCheck = 0
                    } catch {
                        processor.endRecording()
                        sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }
                        deliver(.failure(error))
                    }
                }
            } catch { report(error.localizedDescription) }
        }
    }
    func stopRecording() { sessionQueue.async { [self] in stopRecordingLocked() } }
    private func stopRecordingLocked() {
        guard state == .recording else { return }
        if configuration.mode == .panorama { stopPanoramaLocked(); return }
        setState(.finishing)
        frameQueue.async { [self] in
            guard let recorder = movie else {
                processor.endRecording()
                sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }; return
            }
            movie = nil; processor.endRecording()
            recorder.finish { [self] result in
                let mapped = result.map { url in MediaDraft(url:url,isVideo:true,
                    summary:"\(recorder.settings.mode.rawValue) · \(recorder.settings.resolution.rawValue) output · H:\(recorder.settings.horizonLock ? "on":"off") Z:\(recorder.settings.zoomLock ? "on":"off")") }
                deliver(mapped)
                sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }
            }
        }
    }
    private func computationalBiases(_ mode: ComputationalPhotoMode, maxCount: Int) -> [Float] {
        guard maxCount >= 2 else { return [] }
        switch mode {
        case .off: return []
        case .autoHDR: return maxCount >= 3 ? [-2,0,2] : [-1.5,1.5]
        case .night:
            if maxCount >= 5 { return [-0.7,-0.35,0,0.35,0.7] }
            if maxCount >= 3 { return [-0.7,0,0.7] }
            return [-0.4,0.4]
        case .detailFusion: return maxCount >= 3 ? [-0.35,0,0.35] : [-0.25,0.25]
        }
    }

    private func captureComputationalPhoto(_ config: CameraSettings, codec: AVVideoCodecType) throws -> Bool {
        let biases = computationalBiases(config.computationalPhoto,maxCount:photoOutput.maxBracketedCapturePhotoCount)
        guard biases.count >= 2 else { return false }
        let bracket = biases.map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias:$0) }
        let settings = AVCapturePhotoBracketSettings(rawPixelFormatType:0,processedFormat:[AVVideoCodecKey:codec],bracketedSettings:bracket)
        if photoOutput.isLensStabilizationDuringBracketedCaptureSupported { settings.isLensStabilizationEnabled = true }
        let id = settings.uniqueID
        let delegate = BracketPhotoCapture(id:id,settings:config) { [weak self] result in
            guard let self else { return }
            self.frameQueue.async { [self] in
                do { self.deliver(.success(try self.saveComputationalPhoto(try result.get()))) }
                catch { self.deliver(.failure(error)) }
                self.sessionQueue.async { [self] in
                    self.bracketJobs.removeValue(forKey:id)
                    self.setState(self.wantedRunning ? .ready : .stopped)
                }
            }
        }
        bracketJobs[id] = delegate
        setState(.takingPhoto)
        photoOutput.capturePhoto(with:settings,delegate:delegate)
        return true
    }

    private func saveComputationalPhoto(_ packet: BracketPhotoPacket) throws -> MediaDraft {
        let decoded = packet.images.compactMap { CIImage(data:$0,options:[.applyOrientationProperty:true]) }
        guard decoded.count == packet.images.count, let fused = renderer.fuseBracket(decoded,mode:packet.settings.computationalPhoto) else {
            throw CameraFailure.message("The computational photo frames could not be fused.")
        }
        let host = packet.timestamps.isEmpty ? CMClockGetTime(CMClockGetHostTimeClock()).seconds : hostTime(for:packet.timestamps[packet.timestamps.count/2])
        let processed = try processor.processPhoto(fused,hostTime:host)
        guard let encoded = CaptureMetadata.encodeProcessed(processed,renderer:renderer,efficient:packet.settings.codec == .efficient,settings:packet.settings,sourceData:packet.images.first) else {
            throw CameraFailure.message("The fused computational photo could not be encoded.")
        }
        let url = try MediaFiles.newURL(extension:encoded.1)
        try encoded.0.write(to:url,options:.atomic)
        return MediaDraft(url:url,isVideo:false,summary:"\(packet.settings.computationalPhoto.rawValue) · \(packet.images.count)-frame bracket fusion")
    }

    func capturePhoto() {
        sessionQueue.async { [self] in
            guard state == .ready, let device = videoInput?.device else { return }
            do {
                try MediaFiles.requireSpace()
                let config = configuration
                let codec: AVVideoCodecType = config.codec == .efficient && photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                if config.usesBracketedPhotoPipeline, try captureComputationalPhoto(config,codec:codec) { return }
                let settings: AVCapturePhotoSettings
                if config.raw && !config.livePhoto && !config.isProcessedPhoto {
                    let types = photoOutput.availableRawPhotoPixelFormatTypes
                    let selected: OSType? = config.preferProRAW
                        ? (types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? types.first)
                        : (types.first(where: { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? types.first)
                    if let raw = selected { settings = AVCapturePhotoSettings(rawPixelFormatType:raw,processedFormat:[AVVideoCodecKey:codec]) }
                    else { settings = AVCapturePhotoSettings(format:[AVVideoCodecKey:codec]) }
                } else { settings = AVCapturePhotoSettings(format:[AVVideoCodecKey:codec]) }
                settings.photoQualityPrioritization = config.photoQuality.avValue
                let validDimensions = device.activeFormat.supportedMaxPhotoDimensions.filter {
                    Int64($0.width) * Int64($0.height) <= Int64(photoOutput.maxPhotoDimensions.width) * Int64(photoOutput.maxPhotoDimensions.height)
                }
                if config.photoResolutionMP > 0, let selected = validDimensions.min(by: {
                    abs(Double($0.width)*Double($0.height)/1_000_000-Double(config.photoResolutionMP)) <
                    abs(Double($1.width)*Double($1.height)/1_000_000-Double(config.photoResolutionMP))
                }) { settings.maxPhotoDimensions = selected }
                else { settings.maxPhotoDimensions = validDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) ?? photoOutput.maxPhotoDimensions }
                settings.metadata = CaptureMetadata.photo(config)
                settings.isAutoRedEyeReductionEnabled = config.autoRedEyeReduction && photoOutput.isAutoRedEyeReductionSupported
                settings.isAutoContentAwareDistortionCorrectionEnabled = config.contentAwareDistortionCorrection && photoOutput.isContentAwareDistortionCorrectionEnabled
                settings.isAutoVirtualDeviceFusionEnabled = config.virtualDeviceFusion && photoOutput.isVirtualDeviceFusionSupported
                settings.isCameraCalibrationDataDeliveryEnabled = config.cameraCalibrationData && photoOutput.isCameraCalibrationDataDeliverySupported
                settings.isDepthDataDeliveryEnabled = config.depthData && photoOutput.isDepthDataDeliveryEnabled && !config.raw
                settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
                settings.isDepthDataFiltered = config.depthDataFiltered
                settings.isPortraitEffectsMatteDeliveryEnabled = config.portraitEffectsMatte && photoOutput.isPortraitEffectsMatteDeliveryEnabled && !config.raw
                settings.embedsPortraitEffectsMatteInPhoto = settings.isPortraitEffectsMatteDeliveryEnabled
                settings.enabledSemanticSegmentationMatteTypes = config.semanticMattes && !config.raw ? photoOutput.enabledSemanticSegmentationMatteTypes : []
                settings.embedsSemanticSegmentationMattesInPhoto = !settings.enabledSemanticSegmentationMatteTypes.isEmpty
                if #available(iOS 18.0, *) {
                    settings.isConstantColorEnabled = config.constantColor && photoOutput.isConstantColorEnabled && !config.raw
                    settings.isConstantColorFallbackPhotoDeliveryEnabled = settings.isConstantColorEnabled && config.constantColorFallback
                }
                if device.hasFlash { settings.flashMode = config.flash.avMode }
                var liveURL: URL?
                if config.livePhoto && !config.raw && !config.isProcessedPhoto && photoOutput.isLivePhotoCaptureEnabled {
                    liveURL = try MediaFiles.newURL(extension:"mov"); settings.livePhotoMovieFileURL = liveURL
                    settings.livePhotoMovieMetadata = NativeMovieController.movieMetadata(config)
                }
                let id = settings.uniqueID
                let delegate = PhotoCapture(id:id,settings:config,liveURL:liveURL) { [weak self] result in
                    guard let self else { return }
                    self.frameQueue.async { [self] in
                        do {
                            let packet = try result.get()
                            let draft = try self.savePhoto(packet)
                            self.deliver(.success(draft))
                        } catch { self.deliver(.failure(error)) }
                        self.sessionQueue.async { [self] in
                            self.photoJobs.removeValue(forKey:id)
                            self.setState(self.wantedRunning ? .ready : .stopped)
                        }
                    }
                }
                photoJobs[id] = delegate
                setState(.takingPhoto)
                photoOutput.capturePhoto(with:settings,delegate:delegate)
            } catch { report(error.localizedDescription); setState(wantedRunning ? .ready : .stopped) }
        }
    }
    private func savePhoto(_ packet: PhotoPacket) throws -> MediaDraft {
        var data = packet.data
        var suffix = data.starts(with:[0xff,0xd8]) ? "jpg" : "heic"
        if packet.settings.isProcessedPhoto {
            guard var image = CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CameraFailure.message("Cannot decode this still image.") }
            if packet.settings.mode == .portrait || packet.settings.portraitLighting != .natural {
                let matte = packet.portraitEffectsMatte.map { CIImage(cvPixelBuffer:$0.mattingImage) }
                image = renderer.portraitLighting(image,matte:matte,style:packet.settings.portraitLighting,blurRadius:packet.settings.portraitBlurRadius)
            }
            let processed = try processor.processPhoto(image,hostTime:hostTime(for:packet.timestamp))
            if let encoded = CaptureMetadata.encodeProcessed(processed, renderer: renderer,
                efficient: packet.settings.codec == .efficient, settings: packet.settings, sourceData: data,
                depthData:packet.depthData, portraitEffectsMatte:packet.portraitEffectsMatte) {
                data = encoded.0; suffix = encoded.1
            } else { throw CameraFailure.message("Cannot encode the processed photo.") }
        }
        let url = try MediaFiles.newURL(extension:suffix)
        try data.write(to:url,options:.atomic)
        var rawURL: URL?
        if let raw = packet.rawData {
            rawURL = try MediaFiles.newURL(extension:"dng")
            try raw.write(to:rawURL!,options:.atomic)
        }
        var features: [String] = []
        if packet.hasDepthData { features.append("depth") }
        if packet.hasPortraitEffectsMatte { features.append("portrait matte") }
        if packet.settings.semanticMattes { features.append("semantic mattes") }
        if packet.hasCalibrationData { features.append("calibration") }
        if packet.settings.constantColor { features.append("Constant Color") }
        if packet.settings.mode == .portrait { features.append("\(packet.settings.portraitLighting.rawValue) lighting approx") }
        if packet.settings.hasCustomStyle { features.append("\(packet.settings.photographicStyle.rawValue) style approx") }
        if packet.rawData != nil { features.append(packet.settings.preferProRAW ? "Apple ProRAW" : "RAW") }
        let suffixSummary = features.isEmpty ? "" : " · " + features.joined(separator: ", ")
        return MediaDraft(url:url,liveMovie:packet.liveMovie,raw:rawURL,
            summary:(packet.settings.isProcessedPhoto ? "Processed photo · same lock/crop as preview" : "Native maximum-quality photo") + suffixSummary)
    }
    private func hostTime(for pts: CMTime) -> Double {
        guard pts.isValid && !pts.isIndefinite else { return CMClockGetTime(CMClockGetHostTimeClock()).seconds }
        if let clock = session.synchronizationClock {
            return CMSyncConvertTime(pts,from:clock,to:CMClockGetHostTimeClock()).seconds
        }
        return pts.seconds
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard configuration.scanQRCodes else { return }
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
               let value = code.stringValue, !value.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.onCode?(value) }
                break
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            do { try movie?.appendAudio(sampleBuffer) }
            catch { report(error.localizedDescription); stopRecording() }
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer), now = hostTime(for:pts)
        if configuration.showDetectedText && now-lastTextTime >= 0.75 {
            lastTextTime = now
            let retained = buffer
            textQueue.async { [weak self] in
                guard let self else { return }
                let lines = self.textDetector.recognize(retained)
                DispatchQueue.main.async { [weak self] in self?.onText?(lines) }
            }
        }
        if #available(iOS 26.0, *), configuration.smartFraming && now-lastSmartFramingTime >= 0.35 {
            lastSmartFramingTime = now
            NativeMovieController.applySmartFramingIfNeeded(configuration,engine:self)
        }
        autoreleasepool {
            do {
                let frame = try processor.process(buffer:buffer,hostTime:now)
                if let panorama, let reading = motion.sample(at:now) { panorama.append(frame.overview,yaw:reading.yaw) }
                try movie?.appendVideo(frame.image,sourcePTS:pts)
                if movie != nil && now-lastSpaceCheck > 5 {
                    lastSpaceCheck = now; try MediaFiles.requireSpace()
                }
                if now-lastDiagnosticsTime > 0.1 {
                    lastDiagnosticsTime = now
                    var info = frame.diagnostics
                    info.recordingSeconds = movie?.duration ?? 0
                    info.droppedFrames += movie?.droppedFrames ?? 0
                    if #available(iOS 26.0, *), let device = videoInput?.device, device.activeFormat.isCameraLensSmudgeDetectionSupported {
                        switch device.cameraLensSmudgeDetectionStatus {
                        case .smudged: info.lensStatus = "Clean lens"
                        case .smudgeNotDetected: info.lensStatus = "Clear"
                        case .unknown: info.lensStatus = configuration.lensCleaningHints ? "Checking" : "Off"
                        case .disabled: info.lensStatus = "Off"
                        @unknown default: info.lensStatus = "Unknown"
                        }
                    }
                    if #available(iOS 26.0, *), configuration.smartFraming {
                        info.smartFramingStatus = videoInput?.device.smartFramingMonitor?.recommendedFraming == nil ? "Monitoring" : "Recommended"
                    }
                    DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(info) }
                }
            } catch { report(error.localizedDescription); stopRecording() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { processor.dropped += 1 }
    }
}
