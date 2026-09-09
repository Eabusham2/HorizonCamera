import SwiftUI
import AVFoundation
import Combine
import Photos

@MainActor final class CameraModel: ObservableObject {
    @Published private(set) var settings = CameraSettings()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var diagnostics = FrameDiagnostics()
    @Published private(set) var state: CaptureState = .stopped
    @Published var error: String?
    @Published var notice: String?
    @Published var permissionDenied = false
    @Published var showSettings = false
    @Published var showLibrary = false
    @Published var countdown: Int?
    @Published var focusPoint: Point2?
    @Published var detectedCode: String?
    @Published var detectedText: [String] = []
    @Published var quickTakeLocked=false
    @Published var burstLocked=false
    let library = MediaLibrary()
    let renderer: ImageRenderer?
    let engine: CaptureEngine?
    private let nativeMovie = NativeMovieController()
    private let dualCapture = DualCaptureController()
    private let spatialPhotoCapture = SpatialPhotoController()
    private var requesting = false
    private var timerTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var codeTask: Task<Void, Never>?
    private var burstTask: Task<Void,Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var requestedStartupPermissions = false
    var canConfigure: Bool { state == .ready && countdown == nil }
    var isRecording: Bool { state == .recording }
    var busy: Bool { state == .takingPhoto || state == .finishing || state == .starting }
    var preview: PreviewFeed? { dualCapture.isRecording ? dualCapture.preview : engine?.processor.preview }
    private var settingsURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("camera-settings.json")
    }

    nonisolated static func preparedForLaunch(_ value: CameraSettings) -> CameraSettings {
        var result=value
        result.zoom=1; result.torch=false; result.aeafLock=false
        return result
    }
    nonisolated static func preparedForPersistence(_ value: CameraSettings) -> CameraSettings {
        var result=value
        result.zoom=1; result.torch=false; result.aeafLock=false
        return result
    }

    init() {
        renderer = ImageRenderer()
        engine = renderer.map { CaptureEngine(renderer:$0) }
        if let data=try? Data(contentsOf:settingsURL), let saved=Self.decodeSettingsMigrating(data) {
            settings=Self.preparedForLaunch(saved)
        }
        engine?.onState = { [weak self] state in
            guard let self, !self.nativeMovie.isRecording else { return }
            self.state = state
            UIApplication.shared.isIdleTimerDisabled = state == .recording
        }
        engine?.onCapabilities = { [weak self] capabilities, actual in
            guard let self else { return }
            self.settings = actual
            if let engine = self.engine {
                self.capabilities = NativeMovieController.augment(capabilities, engine: engine)
                self.capabilities.spatialPhoto = self.capabilities.spatialPhoto && SpatialPhotoController.isSupported
                var normalized = actual
                if normalized.centerStage && !self.capabilities.centerStage { normalized.centerStage = false }
                if normalized.smartFraming && !self.capabilities.smartFraming { normalized.smartFraming = false }
                if normalized.lensCleaningHints && !self.capabilities.lensSmudgeDetection { normalized.lensCleaningHints = false }
                if normalized.photoResolutionMP > 0 && !self.capabilities.supportedPhotoResolutionsMP.contains(normalized.photoResolutionMP) { normalized.photoResolutionMP = 0 }
                self.settings = normalized
                NativeMovieController.applyLiveSettings(normalized, engine: engine)
            } else { self.capabilities = capabilities }
        }
        engine?.onDiagnostics = { [weak self] info in self?.diagnostics = info }
        engine?.onCode = { [weak self] value in
            guard let self else { return }
            self.detectedCode = value
            self.codeTask?.cancel()
            self.codeTask = Task { [weak self] in
                try? await Task.sleep(for:.seconds(4))
                if !Task.isCancelled { self?.detectedCode = nil }
            }
        }
        engine?.onText = { [weak self] lines in self?.detectedText = lines }
        engine?.onControlSettings = { [weak self] actual in
            guard let self else { return }
            self.settings = actual
            self.persist()
        }
        engine?.onError = { [weak self] text in if self?.error != text { self?.error = text } }
        engine?.onMedia = { [weak self] result in self?.handleMedia(result) }
        if engine == nil { error = "This device does not provide the Metal renderer required by HorizonCamera." }
    }

    nonisolated static func decodeSettingsMigrating(_ data: Data) -> CameraSettings? {
        do {
            let defaultData = try JSONEncoder().encode(CameraSettings())
            guard var defaults = try JSONSerialization.jsonObject(with:defaultData) as? [String:Any],
                  let saved = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
            defaults.merge(saved) { _,new in new }
            let merged = try JSONSerialization.data(withJSONObject:defaults)
            var decoded = try JSONDecoder().decode(CameraSettings.self,from:merged)
            if decoded.mode == .action {
                let old = decoded
                decoded.mode = .video
                decoded.actionStabilization = true
                decoded.horizonLock = true
                decoded.zoomLock = false
                decoded.normalize(changedFrom:old)
            }
            return decoded
        } catch { return nil }
    }

    private func handleMedia(_ result: Result<MediaDraft, Error>) {
        switch result {
        case .success(let media):
            Task {
                await library.add(media, saveToPhotos: settings.saveToPhotos)
                endBackgroundTask()
            }
        case .failure(let error):
            self.error = error.localizedDescription
            endBackgroundTask()
        }
    }

    func start() async {
        guard !requesting, !showLibrary, !isRecording, !busy, let engine else { return }
        requesting = true; defer { requesting = false }
        let video = AVCaptureDevice.authorizationStatus(for:.video)
        var allowed = video == .authorized
        if video == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for:.video) }
        guard allowed else { permissionDenied = true; error = "Allow Camera access in Settings to use HorizonCamera."; return }
        permissionDenied = false
        var microphone = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined { microphone = await AVCaptureDevice.requestAccess(for:.audio) }
        if settings.audio && !microphone { settings.audio = false }
        if !requestedStartupPermissions {
            requestedStartupPermissions = true
            if PHPhotoLibrary.authorizationStatus(for:.addOnly) == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for:.addOnly) }
            await CaptureLocation.shared.requestAuthorizationOnly()
            engine.motion.requestAuthorizationIfNeeded()
        }
        guard UIApplication.shared.applicationState == .active else { return }
        if settings.includeLocationMetadata { CaptureLocation.shared.request() }
        engine.start(settings:settings,microphoneAllowed:microphone)
    }

    func suspend() {
        timerTask?.cancel(); countdown=nil; settingsTask?.cancel(); codeTask?.cancel(); burstTask?.cancel(); burstLocked=false; quickTakeLocked=false; detectedCode=nil; detectedText=[]
        if nativeMovie.isRecording { nativeMovie.stop() }
        if dualCapture.isRecording { dualCapture.stop() }
        if isRecording || state == .finishing || state == .takingPhoto {
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"Finish camera capture") { [weak self] in DispatchQueue.main.async { self?.endBackgroundTask() } }
            }
        }
        engine?.suspend(); CaptureLocation.shared.stop(); UIApplication.shared.isIdleTimerDisabled = false
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    func change(_ edit: (inout CameraSettings) -> Void) {
        guard canConfigure else { return }
        let old = settings
        var next = old; edit(&next)
        next.normalize(changedFrom: old)
        if next.includeLocationMetadata && !old.includeLocationMetadata { CaptureLocation.shared.request() }
        if !next.includeLocationMetadata && old.includeLocationMetadata { CaptureLocation.shared.stop() }
        settings = next
        settingsTask?.cancel()
        if !next.requiresCaptureReconfiguration(comparedTo: old) {
            engine?.update(next)
            if let engine { NativeMovieController.applyLiveSettings(next,engine:engine) }
            settingsTask = Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(120))
                if !Task.isCancelled { self?.persist() }
            }
        } else {
            settingsTask = Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(70))
                guard !Task.isCancelled, let self else { return }
                engine?.update(settings)
                if let engine { NativeMovieController.applyLiveSettings(settings,engine:engine) }
                persist()
            }
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<CameraSettings,Value>) -> Binding<Value> {
        Binding(get:{ self.settings[keyPath:keyPath] },set:{ value in self.change { $0[keyPath:keyPath] = value } })
    }

    func codecAvailable(_ codec: CodecChoice) -> Bool {
        guard settings.mode.isMovie else { return codec == .efficient || codec == .compatible }
        switch codec {
        case .efficient: return true
        case .compatible: return settings.colorProfile == .sdr
        case .proResLT, .proRes422, .proResHQ: return settings.mode == .video && capabilities.proRes
        case .proResRAW: return settings.mode == .video && !settings.actionStabilization && capabilities.proResRAW
        case .proResRAWHQ: return settings.mode == .video && !settings.actionStabilization && capabilities.proResRAWHQ
        }
    }
    func colorProfileAvailable(_ profile: VideoColorProfile) -> Bool {
        guard settings.mode == .video, !settings.codec.isProResRAW else { return profile == .sdr && !settings.codec.isProResRAW }
        switch profile {
        case .sdr: return true
        case .hdrHLG: return capabilities.hdrHLG && settings.codec != .compatible
        case .dolbyVision84: return capabilities.dolbyVision && settings.codec == .efficient
        case .appleLog: return capabilities.appleLog && settings.codec != .compatible
        case .appleLog2: return capabilities.appleLog2 && settings.codec != .compatible
        }
    }
    func resolutionAvailable(_ resolution: Resolution) -> Bool {
        if settings.codec.isProResRAW {
            guard resolution.isRAWFrameSize else { return false }
            return capabilities.supportedResolutions.contains(resolution)
        }
        if resolution.isRAWFrameSize { return false }
        if resolution == .action2_8K { return settings.actionStabilization && capabilities.supportedResolutions.contains(resolution) }
        if settings.actionStabilization && resolution == .ultraHD { return false }
        return capabilities.supportedResolutions.contains(resolution)
    }
    func frameRateAvailable(_ rate: Double) -> Bool {
        guard let rates=capabilities.supportedFPSByResolution[settings.resolution], rates.contains(where:{abs($0-rate)<0.02}) else { return false }
        if settings.actionStabilization && rate > 60.01 { return false }
        if settings.codec.isProResRAW {
            if settings.resolution == .openGate && rate > 60.01 { return false }
            if settings.resolution == .raw17x9 && rate > 120.01 { return false }
        }
        return true
    }
    func selectCodec(_ codec: CodecChoice) { guard codecAvailable(codec) else { return }; change { $0.codec=codec } }
    func selectColorProfile(_ profile: VideoColorProfile) { guard colorProfileAvailable(profile) else { return }; change { $0.colorProfile=profile } }
    func selectResolution(_ resolution: Resolution) { guard resolutionAvailable(resolution) else { return }; change { $0.resolution=resolution } }
    func selectFrameRate(_ rate: Double) { guard frameRateAvailable(rate) else { return }; change { $0.fps=rate } }

    func selectMode(_ mode: CameraMode) {
        if burstLocked { toggleBurstLock() }
        if mode == .slowMotion && capabilities.supportedSlowMotionFPS.isEmpty { notice = "This lens does not support high-frame-rate slow motion."; return }
        if mode == .cinematic && !capabilities.cinematic { notice = "Cinematic Video requires a supported iPhone, lens, and format on iOS 26+."; return }
        if mode == .portrait && !capabilities.depthData { notice = "Portrait depth capture is not supported by this lens/format."; return }
        if mode == .spatial && !capabilities.spatialVideo { notice = "Spatial Video is not available with this lens/format."; return }
        if mode == .spatialPhoto && !capabilities.spatialPhoto { notice = "Spatial Photo needs a supported multi-camera iPhone."; return }
        if mode == .dualCapture && !capabilities.multiCam { notice = "Dual Capture needs MultiCam support on this iPhone."; return }
        if mode == .action {
            change { $0.mode = .video; $0.actionStabilization = true; $0.torch = false }
            return
        }
        change { $0.mode = mode; $0.torch = false }
    }

    func selectLens(_ lens: LensOption) {
        guard canConfigure else { return }
        settingsTask?.cancel(); settings.zoom = 1
        engine?.update(settings,lensID:lens.id)
    }

    func flipCamera() {
        let front = capabilities.lenses.first(where: { $0.id == capabilities.selectedLens })?.isFront ?? false
        if let target = capabilities.lenses.first(where: { $0.isFront != front && ($0.isVirtual || $0.isFront) }) ??
            capabilities.lenses.first(where: { $0.isFront != front && $0.label == "1×" }) ??
            capabilities.lenses.first(where: { $0.isFront != front }) { selectLens(target) }
    }

    func zoom(_ value: Double, at anchor: Point2? = nil) {
        guard state == .ready || state == .recording else { return }
        settings.zoom = min(max(value,1),12)
        engine?.setZoom(settings.zoom,anchor:anchor)
    }

    func tap(_ point: Point2) {
        guard state == .ready || state == .recording else { return }
        engine?.tap(point); focusPoint = point
        focusTask?.cancel()
        focusTask = Task {
            try? await Task.sleep(for:.seconds(1.3))
            if !Task.isCancelled { focusPoint = nil }
        }
    }

    var currentLensFactor: Double {
        capabilities.lenses.first(where:{$0.id == capabilities.selectedLens})?.factor ?? 1
    }
    var displayZoom: Double { currentLensFactor * settings.zoom }
    var zoomDots: [Double] { capabilities.lenses.filter{!$0.isFront && !$0.isVirtual}.map{$0.factor}.sorted() }
    var zoomRange: ClosedRange<Double> {
        let lo=max(0.5,zoomDots.first ?? 1), hi=max(12,zoomDots.last ?? 1)
        return lo...hi
    }
    func setDisplayZoom(_ requested: Double, at anchor: Point2? = nil) {
        guard state == .ready || state == .recording else { return }
        let backs=capabilities.lenses.filter{!$0.isFront && !$0.isVirtual}.sorted{$0.factor<$1.factor}
        guard !backs.isEmpty else { zoom(requested,at:anchor); return }
        var target=min(max(requested,zoomRange.lowerBound),zoomRange.upperBound)
        if let dot=backs.map({$0.factor}).min(by:{abs($0-target)<abs($1-target)}), abs(dot-target) <= max(0.06,dot*0.045) { target=dot }
        let lens=backs.filter{$0.factor <= target+0.001}.last ?? backs.first!
        let local=min(max(target/lens.factor,1),12)
        settingsTask?.cancel(); settings.zoom=local
        if lens.id != capabilities.selectedLens { engine?.update(settings,lensID:lens.id) }
        else { engine?.setZoom(local,anchor:anchor) }
    }
    func startQuickTake() {
        guard canConfigure, settings.mode == .photo, let engine else { return }
        var quick=settings
        let old=quick
        quick.mode = .video; quick.raw=false; quick.livePhoto=false; quick.timer=0
        quick.videoFraming = .portrait
        quick.resolution=capabilities.supportedResolutions.contains(.ultraHD) ? .ultraHD : .fullHD
        quick.fps=(capabilities.supportedFPSByResolution[quick.resolution] ?? capabilities.supportedFPS).contains(30) ? 30 : ((capabilities.supportedFPSByResolution[quick.resolution] ?? capabilities.supportedFPS).first ?? 30)
        quick.normalize(changedFrom:old)
        quickTakeLocked=false
        engine.startRecording(override:quick)
    }
    func stopQuickTake() { quickTakeLocked=false; engine?.stopRecording() }
    func lockQuickTake() { if isRecording && settings.mode == .photo { quickTakeLocked=true } }
    func captureStillWhileRecording() {
        guard isRecording, settings.mode != .dualCapture else { return }
        engine?.captureVideoStill()
    }
    func toggleBurstLock() {
        guard settings.mode.isPhotoMode && settings.mode != .panorama && settings.mode != .spatialPhoto else { return }
        if burstLocked { burstLocked=false; burstTask?.cancel(); burstTask=nil; return }
        guard canConfigure else { return }
        burstLocked=true
        burstTask=Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && burstLocked {
                if state == .ready { engine?.capturePhoto() }
                try? await Task.sleep(for:.milliseconds(90))
            }
        }
    }

    func shutter() {
        if burstLocked { toggleBurstLock(); return }
        if countdown != nil { timerTask?.cancel(); countdown=nil; return }
        if dualCapture.isRecording { state = .finishing; dualCapture.stop(); return }
        if nativeMovie.isRecording { state = .finishing; nativeMovie.stop(); return }
        if isRecording { engine?.stopRecording(); return }
        guard canConfigure else { return }
        settingsTask?.cancel(); engine?.update(settings)
        if settings.mode == .panorama { engine?.startPanorama(); return }
        if settings.mode == .dualCapture { startDualCapture(); return }
        if settings.mode == .spatialPhoto { captureSpatialPhoto(); return }
        if settings.mode.isMovie {
            if settings.usesNativeMoviePipeline, let engine {
                nativeMovie.start(engine: engine, settings: settings, stateChanged: { [weak self] recording in
                    guard let self else { return }
                    self.state = recording ? .recording : .ready
                    UIApplication.shared.isIdleTimerDisabled = recording
                }, completion: { [weak self] result in self?.handleMedia(result) })
            } else { engine?.startRecording() }
            return
        }
        if settings.timer == 0 { engine?.capturePhoto(); return }
        let seconds = settings.timer
        timerTask = Task { [weak self] in
            guard let self else { return }
            for second in stride(from:seconds,through:1,by:-1) {
                guard !Task.isCancelled else { return }
                countdown = second
                try? await Task.sleep(for:.seconds(1))
            }
            guard !Task.isCancelled else { return }
            countdown = nil; engine?.capturePhoto()
        }
    }

    private func startDualCapture() {
        guard let engine, let renderer else { return }
        let snapshot=settings
        state = .starting
        engine.pauseForExternalCapture { [weak self] in
            guard let self else { return }
            let microphoneAllowed = snapshot.audio && AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
            self.dualCapture.start(renderer:renderer,settings:snapshot,microphoneAllowed:microphoneAllowed,stateChanged:{ [weak self] recording in
                guard let self else { return }
                self.state = recording ? .recording : .finishing
                UIApplication.shared.isIdleTimerDisabled = recording
            },completion:{ [weak self] result in
                guard let self else { return }
                self.handleMedia(result)
                self.state = .stopped
                UIApplication.shared.isIdleTimerDisabled = false
                Task { await self.start() }
            })
        }
    }

    private func captureSpatialPhoto() {
        guard let engine, let renderer else { return }
        let snapshot=settings
        state = .starting
        engine.pauseForExternalCapture { [weak self] in
            guard let self else { return }
            self.state = .takingPhoto
            self.spatialPhotoCapture.capture(renderer:renderer,settings:snapshot) { [weak self] result in
                guard let self else { return }
                self.handleMedia(result)
                self.state = .stopped
                Task { await self.start() }
            }
        }
    }

    func openLibrary() {
        guard !isRecording && !busy && countdown == nil else { return }
        engine?.suspend(); showLibrary = true
    }

    func enableAudio(_ enabled: Bool) {
        guard canConfigure else { return }
        if !enabled { change { $0.audio = false }; return }
        Task {
            var permitted = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined { permitted = await AVCaptureDevice.requestAccess(for:.audio) }
            guard permitted else { settings.audio = false; persist(); return }
            settings.audio = true
            engine?.start(settings:settings,microphoneAllowed:true); persist()
        }
    }

    func resetFraming() {
        guard canConfigure else { return }
        settings.zoom = 1
        engine?.update(settings)
        engine?.frameQueue.async { [weak engine] in engine?.processor.resetGeometry() }
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(at:settingsURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let stored=Self.preparedForPersistence(settings)
            try JSONEncoder().encode(stored).write(to:settingsURL,options:.atomic)
        } catch { notice = "Settings could not be saved: \(error.localizedDescription)" }
    }

    func diagnosticURL() -> URL? {
        do {
            let settingsObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings))
            let object: [String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),
                "version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "source":capabilities.sourceDescription,"settings":settingsObject,
                "motion":diagnostics.motionStatus,"tracking":diagnostics.trackingStatus,
                "confidence":diagnostics.confidence,"deliveredFPS":diagnostics.deliveredFPS,
                "droppedFrames":diagnostics.droppedFrames,"rollDegrees":diagnostics.rollDegrees,
                "sourceDetail":[diagnostics.detail.width,diagnostics.detail.height],
                "note":"Configuration/telemetry only. No images, audio, identifiers or location."]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("HorizonCamera-diagnostics.json")
            try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            return url
        } catch { self.error = error.localizedDescription; return nil }
    }
}
