import AVFoundation
import CoreImage
import Foundation

final class DualCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let preview = PreviewFeed()
    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label:"camera.dual-capture",qos:.userInteractive)
    private let sessionQueue = DispatchQueue(label:"camera.dual-session",qos:.userInitiated)
    private let backOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var renderer: ImageRenderer?
    private var recorder: MovieRecorder?
    private var latestFront: CGImage?
    private var latestFrontPTS: CMTime = .invalid
    private var settings = CameraSettings()
    private var completion: ((Result<MediaDraft,Error>) -> Void)?
    private var stateChanged: ((Bool) -> Void)?
    private let stateLock = NSLock()
    private var active = false

    var isRecording: Bool { stateLock.lock(); defer { stateLock.unlock() }; return active }

    func start(renderer: ImageRenderer, settings: CameraSettings, microphoneAllowed: Bool,
               stateChanged: @escaping (Bool)->Void, completion: @escaping (Result<MediaDraft,Error>)->Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async { completion(.failure(CameraFailure.message("This iPhone does not support simultaneous front and rear camera capture."))) }; return
            }
            do {
                try MediaFiles.requireSpace()
                self.renderer = renderer; self.settings = settings; self.completion = completion; self.stateChanged = stateChanged
                try self.configure(microphoneAllowed:microphoneAllowed)
                let url = try MediaFiles.newURL(extension:"mov")
                self.recorder = try MovieRecorder(url:url,settings:settings,renderer:renderer,microphoneAvailable:microphoneAllowed)
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraFailure.message("The MultiCam session could not start.") }
                self.setActive(true)
                DispatchQueue.main.async { stateChanged(true) }
            } catch { self.fail(error) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in self?.finish() }
        }
    }

    private func configure(microphoneAllowed: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.front) else {
            throw CameraFailure.message("Dual Capture needs both front and rear cameras.")
        }
        try configureDevice(back); try configureDevice(front)
        let backInput = try AVCaptureDeviceInput(device:back), frontInput = try AVCaptureDeviceInput(device:front)
        guard session.canAddInput(backInput), session.canAddInput(frontInput) else { throw CameraFailure.message("This MultiCam configuration cannot use both camera inputs.") }
        session.addInputWithNoConnections(backInput); session.addInputWithNoConnections(frontInput)
        for output in [backOutput,frontOutput] {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self,queue:queue)
            guard session.canAddOutput(output) else { throw CameraFailure.message("This MultiCam configuration cannot add both video outputs.") }
            session.addOutputWithNoConnections(output)
        }
        try connect(backInput,to:backOutput,mirrored:false)
        try connect(frontInput,to:frontOutput,mirrored:false)
        if microphoneAllowed, let microphone = AVCaptureDevice.default(for:.audio) {
            let input = try AVCaptureDeviceInput(device:microphone)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput); audioOutput.setSampleBufferDelegate(self,queue:queue) }
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playAndRecord,mode:.videoRecording,options:[.defaultToSpeaker,.allowBluetooth])
            try? audio.setActive(true)
        }
        guard session.hardwareCost <= 1.0, session.systemPressureCost <= 1.0 else {
            throw CameraFailure.message("This front/rear MultiCam combination exceeds the iPhone's capture budget. Try another device or close other camera apps.")
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= 1280 && d.width <= 1920 && d.height >= 720 &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }.sorted { a,b in
            let da=CMVideoFormatDescriptionGetDimensions(a.formatDescription), db=CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let sa=abs(Int(da.width)-1280)+abs(Int(da.height)-720), sb=abs(Int(db.width)-1280)+abs(Int(db.height)-720)
            return sa < sb
        }
        guard let format=candidates.first else { throw CameraFailure.message("A camera does not provide a MultiCam-safe 720p/30 format.") }
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        device.activeFormat=format
        device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30)
        device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
    }

    private func connect(_ input: AVCaptureDeviceInput, to output: AVCaptureVideoDataOutput, mirrored: Bool) throws {
        guard let port=input.ports.first(where:{$0.mediaType == .video}) else { throw CameraFailure.message("A MultiCam video port is missing.") }
        let connection=AVCaptureConnection(inputPorts:[port],output:output)
        guard session.canAddConnection(connection) else { throw CameraFailure.message("A MultiCam video connection is unsupported.") }
        session.addConnection(connection)
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring=false; connection.isVideoMirrored=mirrored }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
    }

    private func normalized(_ buffer: CVPixelBuffer, mirror: Bool) -> CIImage {
        var image=CIImage(cvPixelBuffer:buffer)
        if mirror { image=image.oriented(.upMirrored) }
        return image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput { do { try recorder?.appendAudio(sampleBuffer) } catch { fail(error) }; return }
        guard let buffer=CMSampleBufferGetImageBuffer(sampleBuffer), let renderer else { return }
        let pts=CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === frontOutput {
            let image=normalized(buffer,mirror:true)
            latestFront=renderer.context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:renderer.colorSpace)
            latestFrontPTS=pts
            return
        }
        guard output === backOutput, let frontCG=latestFront, latestFrontPTS.isValid, abs(pts.seconds-latestFrontPTS.seconds) < 0.20 else { return }
        do {
            let composite=DualCaptureComposer.compose(back:normalized(buffer,mirror:false),front:CIImage(cgImage:frontCG),layout:settings.dualCaptureLayout,canvas:CGSize(width:settings.outputSize.width,height:settings.outputSize.height))
            try recorder?.appendVideo(composite,sourcePTS:pts)
            let size=settings.outputSize
            let plan=CropPlan(source:size,output:size,angle:0,zoom:1,scale:1,center:size.center,wasClamped:false,halfFootprint:Point2(size.width/2,size.height/2))
            var diagnostics=FrameDiagnostics(); diagnostics.trackingStatus="Dual Capture"; diagnostics.detail=size
            preview.publish(PreviewFrame(image:composite,recordingImage:composite,overview:composite,plan:plan,recordingPlan:plan,target:nil,trackingGood:true,diagnostics:diagnostics))
        } catch { fail(error) }
    }

    private func finish() {
        guard isRecording else { return }
        setActive(false); session.stopRunning(); preview.publish(nil)
        let recorder=self.recorder; self.recorder=nil
        guard let recorder else { fail(CameraFailure.message("Dual Capture recorder is missing.")); return }
        recorder.finish { [weak self] result in
            guard let self else { return }
            try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                self.stateChanged?(false)
                self.completion?(result.map { MediaDraft(url:$0,isVideo:true,summary:"Dual Capture · \(self.settings.dualCaptureLayout.rawValue) · simultaneous front + rear") })
                self.completion=nil; self.stateChanged=nil
            }
        }
    }

    private func fail(_ error: Error) {
        setActive(false); if session.isRunning { session.stopRunning() }; preview.publish(nil); recorder=nil
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.stateChanged?(false); self.completion?(.failure(error)); self.completion=nil; self.stateChanged=nil
        }
    }
    private func setActive(_ value: Bool) { stateLock.lock(); active=value; stateLock.unlock() }
}
