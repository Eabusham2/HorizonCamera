import SwiftUI
import AVFoundation
import Combine

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
    let library = MediaLibrary()
    let renderer: ImageRenderer?
    let engine: CaptureEngine?
    private var requesting = false
    private var timerTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var canConfigure: Bool { state == .ready && countdown == nil }
    var isRecording: Bool { state == .recording }
    var busy: Bool { state == .takingPhoto || state == .finishing || state == .starting }
    var preview: PreviewFeed? { engine?.processor.preview }
    private var settingsURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("camera-settings.json")
    }
    init() {
        renderer = ImageRenderer()
        engine = renderer.map { CaptureEngine(renderer:$0) }
        if let data = try? Data(contentsOf:settingsURL), let saved = try? JSONDecoder().decode(CameraSettings.self,from:data) {
            settings = saved; settings.torch = false; settings.aeafLock = false
        }
        engine?.onState = { [weak self] state in
            self?.state = state
            UIApplication.shared.isIdleTimerDisabled = state == .recording
        }
        engine?.onCapabilities = { [weak self] capabilities, actual in
            self?.capabilities = capabilities; self?.settings = actual
        }
        engine?.onDiagnostics = { [weak self] info in self?.diagnostics = info }
        engine?.onError = { [weak self] text in
            // Do not queue hundreds of identical alerts when the camera stalls.
            if self?.error != text { self?.error = text }
        }
        engine?.onMedia = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let media):
                Task {
                    await library.add(media,saveToPhotos:settings.saveToPhotos)
                    notice = library.message; endBackgroundTask()
                }
            case .failure(let error): self.error = error.localizedDescription; endBackgroundTask()
            }
        }
        if engine == nil { error = "This device does not provide the Metal renderer required by HorizonCamera." }
    }
    func start() async {
        guard !requesting, !showLibrary, !isRecording, !busy, let engine else { return }
        requesting = true; defer { requesting = false }
        let video = AVCaptureDevice.authorizationStatus(for:.video)
        let allowed = video == .authorized || (video == .notDetermined && (await AVCaptureDevice.requestAccess(for:.video)))
        guard allowed else { permissionDenied = true; error = "Allow Camera access in Settings to use HorizonCamera."; return }
        permissionDenied = false
        var microphone = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        if settings.audio && AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined {
            microphone = await AVCaptureDevice.requestAccess(for:.audio)
        }
        if settings.audio && !microphone { settings.audio = false; notice = "Microphone permission is off. Videos will be silent." }
        guard UIApplication.shared.applicationState == .active else { return }
        engine.start(settings:settings,microphoneAllowed:microphone)
    }
    func suspend() {
        timerTask?.cancel(); countdown = nil; settingsTask?.cancel()
        if isRecording || state == .finishing || state == .takingPhoto {
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"Finish camera capture") { [weak self] in
                    DispatchQueue.main.async { self?.endBackgroundTask() }
                }
            }
        }
        engine?.suspend(); UIApplication.shared.isIdleTimerDisabled = false
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func change(_ edit: (inout CameraSettings) -> Void) {
        guard canConfigure else { return }
        var next = settings; edit(&next)
        next.zoom = min(max(next.zoom,1),12)
        settings = next
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            engine?.update(settings); persist()
        }
    }
    func binding<Value>(_ keyPath: WritableKeyPath<CameraSettings,Value>) -> Binding<Value> {
        Binding(get:{ self.settings[keyPath:keyPath] },set:{ value in self.change { $0[keyPath:keyPath] = value } })
    }
    func selectMode(_ mode: CameraMode) {
        if mode == .slowMotion && !capabilities.supports120 { notice = "This lens does not support 120 fps slow motion."; return }
        change { $0.mode = mode; $0.torch = false }
    }
    func selectLens(_ lens: LensOption) {
        guard canConfigure else { return }
        settingsTask?.cancel(); settings.zoom = 1
        engine?.update(settings,lensID:lens.id)
    }
    func flipCamera() {
        let front = capabilities.lenses.first(where: { $0.id == capabilities.selectedLens })?.isFront ?? false
        if let target = capabilities.lenses.first(where: { $0.isFront != front && ($0.label == "1×" || $0.isFront) }) ?? capabilities.lenses.first(where: { $0.isFront != front }) {
            selectLens(target)
        }
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
    func shutter() {
        if countdown != nil { timerTask?.cancel(); countdown = nil; return }
        if isRecording { engine?.stopRecording(); return }
        guard canConfigure else { return }
        // Flush an outstanding settings edit before scheduling the capture.
        settingsTask?.cancel(); engine?.update(settings)
        if settings.mode.isMovie { engine?.startRecording(); return }
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
            guard permitted else { notice = "Enable Microphone access in iOS Settings first."; return }
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
            try JSONEncoder().encode(settings).write(to:settingsURL,options:.atomic)
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
