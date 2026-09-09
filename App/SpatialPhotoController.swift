import AVFoundation
import CoreImage
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

final class SpatialPhotoController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label:"camera.spatial-photo",qos:.userInteractive)
    private let sessionQueue = DispatchQueue(label:"camera.spatial-photo-session",qos:.userInitiated)
    private let leftOutput = AVCaptureVideoDataOutput(), rightOutput = AVCaptureVideoDataOutput()
    private var leftDevice: AVCaptureDevice?, rightDevice: AVCaptureDevice?
    private var leftImage: CGImage?, rightImage: CGImage?
    private var leftPTS: CMTime = .invalid, rightPTS: CMTime = .invalid
    private var renderer: ImageRenderer?
    private var settings = CameraSettings()
    private var completion: ((Result<MediaDraft,Error>)->Void)?
    private var finished = false

    static var isSupported: Bool {
        guard #available(iOS 18.0,*), AVCaptureMultiCamSession.isMultiCamSupported else { return false }
        let devices=physicalRearDevices()
        for i in devices.indices { for j in devices.indices where j > i {
            if AVCaptureDevice.extrinsicMatrix(from:devices[i],to:devices[j]) != nil { return true }
        }}
        return false
    }

    func capture(renderer: ImageRenderer, settings: CameraSettings, completion: @escaping (Result<MediaDraft,Error>)->Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard #available(iOS 18.0,*) else { DispatchQueue.main.async { completion(.failure(CameraFailure.message("Spatial Photo requires iOS 18 or later."))) }; return }
            do {
                try MediaFiles.requireSpace()
                self.renderer=renderer; self.settings=settings; self.completion=completion; self.finished=false
                try self.configure()
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraFailure.message("The stereo MultiCam session could not start.") }
            } catch { self.fail(error) }
        }
    }

    private static func physicalRearDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInUltraWideCamera,.builtInWideAngleCamera,.builtInTelephotoCamera],mediaType:.video,position:.back).devices.filter { !$0.isVirtualDevice }
    }

    @available(iOS 18.0,*)
    private func configure() throws {
        let pair=try choosePair()
        leftDevice=pair.0; rightDevice=pair.1
        session.beginConfiguration(); defer { session.commitConfiguration() }
        try configureDevice(pair.0); try configureDevice(pair.1)
        let li=try AVCaptureDeviceInput(device:pair.0), ri=try AVCaptureDeviceInput(device:pair.1)
        guard session.canAddInput(li),session.canAddInput(ri) else { throw CameraFailure.message("This iPhone cannot run the selected rear cameras simultaneously.") }
        session.addInputWithNoConnections(li); session.addInputWithNoConnections(ri)
        for output in [leftOutput,rightOutput] {
            output.alwaysDiscardsLateVideoFrames=true
            output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self,queue:queue)
            guard session.canAddOutput(output) else { throw CameraFailure.message("A stereo video output is unavailable.") }
            session.addOutputWithNoConnections(output)
        }
        try connect(li,to:leftOutput); try connect(ri,to:rightOutput)
        guard session.hardwareCost <= 1.0, session.systemPressureCost <= 1.0 else { throw CameraFailure.message("This rear-camera stereo pair exceeds the iPhone's simultaneous capture budget.") }
    }

    @available(iOS 18.0,*)
    private func choosePair() throws -> (AVCaptureDevice,AVCaptureDevice) {
        let devices=Self.physicalRearDevices()
        var best:(AVCaptureDevice,AVCaptureDevice,Double)?
        for i in devices.indices { for j in devices.indices where j > i {
            var a=devices[i],b=devices[j]
            guard let raw=AVCaptureDevice.extrinsicMatrix(from:a,to:b), var m=decodeExtrinsic(raw) else { continue }
            if m.columns.3.x < 0, let reverse=AVCaptureDevice.extrinsicMatrix(from:b,to:a), let rm=decodeExtrinsic(reverse) { swap(&a,&b); m=rm }
            let baseline=simd_length(m.columns.3)
            guard baseline > 1 else { continue }
            let fovGap=abs(Double(a.activeFormat.videoFieldOfView-b.activeFormat.videoFieldOfView))
            let score=fovGap + Double(max(0,10-baseline))*3
            if best == nil || score < best!.2 { best=(a,b,score) }
        }}
        guard let best else { throw CameraFailure.message("No factory-calibrated physical rear-camera pair is available for a spatial photo.") }
        return (best.0,best.1)
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        let formats=device.formats.filter { f in
            let d=CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= 1280 && d.width <= 1920 && d.height >= 720 && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }.sorted { a,b in
            let da=CMVideoFormatDescriptionGetDimensions(a.formatDescription),db=CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width)-1280)+abs(Int(da.height)-720) < abs(Int(db.width)-1280)+abs(Int(db.height)-720)
        }
        guard let format=formats.first else { throw CameraFailure.message("A rear camera lacks a stereo-safe 720p/30 format.") }
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        device.activeFormat=format; device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30); device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
    }

    private func connect(_ input: AVCaptureDeviceInput,to output: AVCaptureVideoDataOutput) throws {
        guard let port=input.ports.first(where:{$0.mediaType == .video}) else { throw CameraFailure.message("A stereo camera port is missing.") }
        let connection=AVCaptureConnection(inputPorts:[port],output:output)
        guard session.canAddConnection(connection) else { throw CameraFailure.message("This stereo camera connection is unsupported.") }
        session.addConnection(connection)
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
    }

    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard !finished,let buffer=CMSampleBufferGetImageBuffer(sampleBuffer),let renderer else { return }
        var image=CIImage(cvPixelBuffer:buffer).transformed(by:CGAffineTransform(translationX:-CIImage(cvPixelBuffer:buffer).extent.minX,y:-CIImage(cvPixelBuffer:buffer).extent.minY))
        let maxW:CGFloat=1280
        if image.extent.width > maxW { let scale=maxW/image.extent.width; image=image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1.0]) }
        guard let cg=renderer.context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:renderer.colorSpace) else { return }
        let pts=CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === leftOutput { leftImage=cg; leftPTS=pts } else if output === rightOutput { rightImage=cg; rightPTS=pts } else { return }
        guard let leftImage,let rightImage,leftPTS.isValid,rightPTS.isValid,abs(leftPTS.seconds-rightPTS.seconds) < 0.08 else { return }
        finished=true
        let left=leftImage,right=rightImage
        sessionQueue.async { [weak self] in self?.finish(left:left,right:right) }
    }

    private func finish(left:CGImage,right:CGImage) {
        session.stopRunning()
        do {
            guard #available(iOS 18.0,*),let ld=leftDevice,let rd=rightDevice,let raw=AVCaptureDevice.extrinsicMatrix(from:ld,to:rd),let extrinsic=decodeExtrinsic(raw) else {
                throw CameraFailure.message("Factory stereo calibration became unavailable.")
            }
            let target=CGSize(width:min(left.width,right.width),height:min(left.height,right.height))
            guard let renderer else { throw CameraFailure.message("Spatial Photo renderer is unavailable.") }
            let commonFOV=Double(min(ld.activeFormat.videoFieldOfView,rd.activeFormat.videoFieldOfView))
            let l=try normalize(CGImage:left,sourceFOV:Double(ld.activeFormat.videoFieldOfView),targetFOV:commonFOV,to:target,renderer:renderer)
            let r=try normalize(CGImage:right,sourceFOV:Double(rd.activeFormat.videoFieldOfView),targetFOV:commonFOV,to:target,renderer:renderer)
            let rightPosition=[Double(extrinsic.columns.3.x)/1000,Double(extrinsic.columns.3.y)/1000,Double(extrinsic.columns.3.z)/1000]
            let rightRotation=[Double(extrinsic.columns.0.x),Double(extrinsic.columns.1.x),Double(extrinsic.columns.2.x),
                               Double(extrinsic.columns.0.y),Double(extrinsic.columns.1.y),Double(extrinsic.columns.2.y),
                               Double(extrinsic.columns.0.z),Double(extrinsic.columns.1.z),Double(extrinsic.columns.2.z)]
            let data=try SpatialPhotoEncoder.encode(left:l,right:r,commonFOV:commonFOV,rightPosition:rightPosition,rightRotation:rightRotation,settings:settings)
            let url=try MediaFiles.newURL(extension:"heic"); try data.write(to:url,options:.atomic)
            let baseline=simd_length(extrinsic.columns.3)
            DispatchQueue.main.async { [weak self] in self?.complete(.success(MediaDraft(url:url,isVideo:false,summary:String(format:"Spatial Photo · stereo HEIC · factory baseline %.1f mm",baseline)))) }
        } catch { DispatchQueue.main.async { [weak self] in self?.complete(.failure(error)) } }
    }

    private func normalize(CGImage cg:CGImage,sourceFOV:Double,targetFOV:Double,to size:CGSize,renderer:ImageRenderer) throws -> CGImage {
        var image=CIImage(cgImage:cg)
        let sourceRadians=max(1,min(179,sourceFOV)) * .pi/180, targetRadians=max(1,min(179,targetFOV)) * .pi/180
        let fraction=min(1,tan(targetRadians/2)/tan(sourceRadians/2))
        let matchedWidth=max(2,image.extent.width*CGFloat(fraction))
        image=image.cropped(to:CGRect(x:image.extent.midX-matchedWidth/2,y:image.extent.minY,width:matchedWidth,height:image.extent.height))
        image=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let rect=CGRect(origin:.zero,size:size)
        let scale=max(size.width/image.extent.width,size.height/image.extent.height)
        var value=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        value=value.cropped(to:CGRect(x:value.extent.midX-size.width/2,y:value.extent.midY-size.height/2,width:size.width,height:size.height))
            .transformed(by:CGAffineTransform(translationX:-value.extent.minX,y:-value.extent.minY))
        guard let out=renderer.context.createCGImage(value,from:rect,format:.RGBA8,colorSpace:renderer.colorSpace) else { throw CameraFailure.message("A stereo eye image could not be normalized.") }
        return out
    }

    private func decodeExtrinsic(_ data:Data) -> matrix_float4x3? {
        guard data.count >= MemoryLayout<matrix_float4x3>.size else { return nil }
        var matrix=matrix_float4x3(columns:(SIMD3<Float>(repeating:0),SIMD3<Float>(repeating:0),SIMD3<Float>(repeating:0),SIMD3<Float>(repeating:0)))
        _=withUnsafeMutableBytes(of:&matrix) { data.copyBytes(to:$0) }
        return matrix
    }

    private func fail(_ error:Error) { if session.isRunning { session.stopRunning() }; DispatchQueue.main.async { [weak self] in self?.complete(.failure(error)) } }
    private func complete(_ result:Result<MediaDraft,Error>) { completion?(result); completion=nil; leftImage=nil; rightImage=nil; leftDevice=nil; rightDevice=nil; renderer=nil }
}
