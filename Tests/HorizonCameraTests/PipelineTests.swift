import XCTest
import AVFoundation
import CoreImage
import Metal
import AudioToolbox
import ImageIO
@testable import HorizonCamera

final class PipelineTests: XCTestCase {
    private func makeRenderer() throws -> ImageRenderer {
        try XCTUnwrap(ImageRenderer(), "The simulator must provide Metal for the actual pipeline tests.")
    }
    private func pattern(width: Double, height: Double) -> CIImage {
        let bounds = CGRect(x:0,y:0,width:width,height:height)
        var image = CIImage(color:CIColor(red:0.08,green:0.12,blue:0.20)).cropped(to:bounds)
        let colors = [CIColor(red:0.9,green:0.1,blue:0.1), CIColor(red:0.1,green:0.8,blue:0.2),
                      CIColor(red:0.1,green:0.2,blue:0.9), CIColor(red:0.9,green:0.8,blue:0.1)]
        for row in 0..<2 {
            for column in 0..<2 {
                let rect = CGRect(x:Double(column)*width/2,y:Double(row)*height/2,width:width/2,height:height/2)
                image = CIImage(color:colors[row*2+column]).cropped(to:rect).composited(over:image)
            }
        }
        return image.cropped(to:bounds)
    }
    private func pixel(_ image:CIImage, _ point:Point2, renderer:ImageRenderer) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:4)
        bytes.withUnsafeMutableBytes { memory in
            renderer.context.render(image,toBitmap:memory.baseAddress!,rowBytes:4,
                bounds:CGRect(x:floor(point.x),y:floor(point.y),width:1,height:1),
                format:.RGBA8,colorSpace:renderer.colorSpace)
        }
        return bytes
    }
    private func buffer(_ image:CIImage, renderer:ImageRenderer) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault,Int(image.extent.width),Int(image.extent.height),
            kCVPixelFormatType_32BGRA,[kCVPixelBufferMetalCompatibilityKey as String:true,
                                     kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&value)
        XCTAssertEqual(code,kCVReturnSuccess)
        let result = try XCTUnwrap(value)
        renderer.render(image,into:result)
        return result
    }
    private func videoBuffer(_ image:CIImage, renderer:ImageRenderer) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault,Int(image.extent.width),Int(image.extent.height),
            kCVPixelFormatType_32BGRA,[kCVPixelBufferMetalCompatibilityKey as String:true,
                                     kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&value)
        XCTAssertEqual(code,kCVReturnSuccess)
        let result = try XCTUnwrap(value)
        renderer.renderVideo(image,into:result)
        return result
    }
    func testActualCoreImagePixelsFollowTheSharedInverseTransform() throws {
        let renderer = try makeRenderer(), source = pattern(width:400,height:600)
        for angle in [0.0,0.6,Double.pi/2,Double.pi,3*Double.pi/2] {
            let plan = try CropGeometry.plan(source:Size2(400,600),output:Size2(240,160),
                angle:angle,zoom:1.5,fullTurn:true,reserve:0.9)
            let output = renderer.transform(source,plan:plan)
            for p in [Point2(24,24),Point2(210,24),Point2(24,130),Point2(210,130)] {
                let input = plan.outputToSource(Point2(p.x+0.5,p.y+0.5))
                if abs(input.x-200)<4 || abs(input.y-300)<4 { continue }
                let actual = pixel(output,p,renderer:renderer)
                let expected = pixel(source,input,renderer:renderer)
                for i in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[i])-Int(expected[i])),3,"angle=\(angle), pixel=\(p)") }
            }
        }
    }
    func testRenderedFullTurnCropContainsNoTransparentOrBlackCorners() throws {
        let renderer = try makeRenderer()
        let source = CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:360,height:640))
        for degrees in stride(from:0.0,through:360,by:15) {
            let p = try CropGeometry.plan(source:Size2(360,640),output:Size2(192,108),
                angle:degrees * .pi/180,fullTurn:true,reserve:0.97,requestedCenter:Point2(-900,9000))
            let output = renderer.transform(source,plan:p)
            for point in [Point2(1,1),Point2(190,1),Point2(1,106),Point2(190,106)] {
                let value = pixel(output,point,renderer:renderer)
                XCTAssertGreaterThan(value[0],240);XCTAssertGreaterThan(value[3],250)
            }
        }
    }
    func testPinchUsesThePointUnderTheFingersAndPublishesTheSameImage() throws {
        let renderer = try makeRenderer()
        let processor = FrameProcessor(motion:MotionService(),renderer:renderer)
        var settings = CameraSettings();settings.horizonLock=false;settings.zoomLock=false
        processor.configure(settings,front:false)
        let input = try buffer(pattern(width:360,height:640),renderer:renderer)
        let first = try processor.process(buffer:input,hostTime:1)
        let anchor = Point2(0.3,0.65)
        let source = first.plan.outputToSource(Point2(anchor.x*first.plan.output.width,(1-anchor.y)*first.plan.output.height))
        processor.setZoom(3,atUIKit:anchor)
        let second = try processor.process(buffer:input,hostTime:1.04)
        let mapped = second.plan.sourceToOutput(source)
        XCTAssertEqual(mapped.x,anchor.x*second.plan.output.width,accuracy:0.001)
        XCTAssertEqual(mapped.y,(1-anchor.y)*second.plan.output.height,accuracy:0.001)
        let preview = try XCTUnwrap(processor.preview.snapshot())
        XCTAssertEqual(preview.image.extent,second.image.extent)
        XCTAssertEqual(preview.plan.center,second.plan.center)
        XCTAssertEqual(pixel(preview.image,Point2(300,400),renderer:renderer),pixel(second.image,Point2(300,400),renderer:renderer))
    }
    private func trackingImage(dx:Double,dy:Double) -> CIImage {
        let bounds = CGRect(x:0,y:0,width:640,height:480)
        var image = CIImage(color:CIColor(red:0.12,green:0.12,blue:0.12)).cropped(to:bounds)
        let border = CGRect(x:220+dx,y:160+dy,width:120,height:120)
        image = CIImage(color:.white).cropped(to:border).composited(over:image)
        for row in 0..<6 {
            for column in 0..<6 {
                let value = Double((row*19+column*31+7)%37)/37
                let color = CIColor(red:value,green:1-value,blue:Double((row+column*2)%5)/5)
                let tile = CGRect(x:226+dx+Double(column)*18,y:166+dy+Double(row)*18,width:17,height:17)
                image = CIImage(color:color).cropped(to:tile).composited(over:image)
            }
        }
        return image.cropped(to:bounds)
    }
    func testVisionTracksActualTranslatedImageContent() throws {
        let tracker = SubjectTracker()
        tracker.seed(normalizedBox:CGRect(x:220.0/640,y:160.0/480,width:120.0/640,height:120.0/480),anchor:Point2(0.3,0.7))
        for index in 0...4 {
            tracker.update(image:trackingImage(dx:Double(index)*4,dy:Double(index)*3),time:Double(index)*0.04)
        }
        XCTAssertEqual(tracker.state,.locked)
        let point = try XCTUnwrap(tracker.target)
        XCTAssertEqual(point.x,296.0/640,accuracy:0.035)
        XCTAssertEqual(point.y,232.0/480,accuracy:0.035)
        XCTAssertEqual(tracker.anchor,Point2(0.3,0.7))
        tracker.reset();XCTAssertNil(tracker.target);XCTAssertEqual(tracker.state,.idle)
    }
    private func audioPacket(pts:Double,index:Int) throws -> CMSampleBuffer {
        let count = 1600
        var asbd = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,
            mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket:4,
            mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:1,mBitsPerChannel:32,mReserved:0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,
            layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,
            blockLength:count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,
            dataLength:count*4,flags:0,blockBufferOut:&block),noErr)
        let data = (0..<count).map { sample in Float(sin(Double(index*count+sample)*2 * .pi*440/48000)*0.2) }
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with:bytes.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:bytes.count)
        }
        XCTAssertEqual(status,noErr)
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),
            presentationTimeStamp:CMTime(seconds:pts,preferredTimescale:48000),decodeTimeStamp:.invalid)
        var sampleSize = 4
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,
            sampleCount:count,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,
            sampleSizeArray:&sampleSize,sampleBufferOut:&result),noErr)
        return try XCTUnwrap(result)
    }
    func testMovieContainsProcessedPixelsAndRetimedAudioNotJustPreviewEffects() async throws {
        let renderer = try makeRenderer()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at:url) }
        var settings = CameraSettings();settings.codec = .compatible;settings.videoFraming = .landscape;settings.horizonLock = true
        let recorder = try MovieRecorder(url:url,settings:settings,renderer:renderer,microphoneAvailable:true)
        let source = pattern(width:2160,height:3840)
        let plan = try CropGeometry.plan(source:Size2(2160,3840),output:settings.outputSize,angle:.pi/2,fullTurn:true,reserve:0.97)
        let processed = renderer.transform(source,plan:plan)
        for index in 0..<18 {
            let seconds = 100+Double(index)/30
            try recorder.appendVideo(processed,sourcePTS:CMTime(seconds:seconds,preferredTimescale:60000))
            try recorder.appendAudio(audioPacket(pts:seconds,index:index))
            try await Task.sleep(for:.milliseconds(35))
        }
        let finished: URL = try await withCheckedThrowingContinuation { continuation in
            recorder.finish { result in continuation.resume(with:result) }
        }
        XCTAssertEqual(finished,url);XCTAssertGreaterThanOrEqual(recorder.writtenFrames,10)
        let asset = AVURLAsset(url:url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds,0.3);XCTAssertLessThan(duration.seconds,1)
        let videos = try await asset.loadTracks(withMediaType:.video)
        let audios = try await asset.loadTracks(withMediaType:.audio)
        let video = try XCTUnwrap(videos.first), audio = try XCTUnwrap(audios.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size,CGSize(width:1920,height:1080))
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(videoRange.start.seconds,0,accuracy:0.001)
        XCTAssertLessThan(abs(audioRange.start.seconds-videoRange.start.seconds),0.1)
        XCTAssertGreaterThan(audioRange.duration.seconds,0.3)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:video,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);XCTAssertTrue(reader.startReading())
        let frame = try XCTUnwrap(output.copyNextSampleBuffer())
        let decoded = CIImage(cvPixelBuffer:try XCTUnwrap(CMSampleBufferGetImageBuffer(frame)))
        let expectedVideo = CIImage(cvPixelBuffer:try videoBuffer(processed,renderer:renderer))
        for point in [Point2(200,200),Point2(1700,200),Point2(200,900),Point2(1700,900)] {
            let actual = pixel(decoded,point,renderer:renderer), expected = pixel(expectedVideo,point,renderer:renderer)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[channel])-Int(expected[channel])),18) }
        }
        reader.cancelReading()
    }
    func testEmptyMovieCannotBeReportedAsSaved() async throws {
        let renderer = try makeRenderer()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let recorder = try MovieRecorder(url:url,settings:CameraSettings(),renderer:renderer,microphoneAvailable:false)
        let result: Result<URL,Error> = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning:$0) }
        }
        if case .success = result { XCTFail("An empty recording must fail.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testProcessedStillHasSameCropAndDoesNotUpscaleToNativePhotoResolution() throws {
        let renderer = try makeRenderer(), processor = FrameProcessor(motion:MotionService(),renderer:try makeRenderer())
        var settings = CameraSettings();settings.mode = .photo;settings.horizonLock = false;settings.zoom = 2
        processor.configure(settings,front:false)
        let source = pattern(width:1080,height:1920)
        let frame = try processor.process(buffer:buffer(source,renderer:renderer),hostTime:2)
        let still = try processor.processPhoto(source,hostTime:2)
        XCTAssertLessThanOrEqual(still.extent.width,frame.plan.sourceDetail.width+2)
        XCTAssertLessThanOrEqual(still.extent.height,frame.plan.sourceDetail.height+2)
        let data = try XCTUnwrap(renderer.context.jpegRepresentation(of:still,colorSpace:renderer.colorSpace,options:[:]))
        let decoded = try XCTUnwrap(CIImage(data:data,options:[.applyOrientationProperty:true]))
        XCTAssertEqual(decoded.extent.size,still.extent.size)
        for n in [Point2(0.2,0.2),Point2(0.8,0.8)] {
            let a = pixel(still,Point2(n.x*still.extent.width,n.y*still.extent.height),renderer:renderer)
            let b = pixel(frame.image,Point2(n.x*frame.image.extent.width,n.y*frame.image.extent.height),renderer:renderer)
            for i in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),5) }
        }
    }
    func testNativePhotoExtrasAreMutuallyExclusiveAndDisabledByProcessing() {
        var base = CameraSettings(); base.mode = .photo; base.horizonLock = false; base.zoomLock = false; base.zoom = 1; base.filter = .original; base.photoFraming = .classic
        var live = base; live.livePhoto = true; live.normalize(changedFrom:base)
        XCTAssertTrue(live.livePhoto); XCTAssertFalse(live.raw); XCTAssertFalse(live.isProcessedPhoto)
        var raw = live; raw.raw = true; raw.normalize(changedFrom:live)
        XCTAssertTrue(raw.raw); XCTAssertFalse(raw.livePhoto)
        var liveAgain = raw; liveAgain.livePhoto = true; liveAgain.normalize(changedFrom:raw)
        XCTAssertTrue(liveAgain.livePhoto); XCTAssertFalse(liveAgain.raw)
        var square = liveAgain; square.photoFraming = .square; square.normalize(changedFrom:liveAgain)
        XCTAssertTrue(square.isProcessedPhoto); XCTAssertFalse(square.livePhoto); XCTAssertFalse(square.raw)
    }
    func testNonClassicPhotoFramingProducesRequestedAspect() throws {
        let renderer = try makeRenderer(), processor = FrameProcessor(motion:MotionService(),renderer:try makeRenderer())
        var settings = CameraSettings(); settings.mode = .photo; settings.horizonLock = false; settings.photoFraming = .landscape
        processor.configure(settings,front:false)
        let source = pattern(width:1080,height:1920)
        _ = try processor.process(buffer:buffer(source,renderer:renderer),hostTime:3)
        let still = try processor.processPhoto(source,hostTime:3)
        XCTAssertTrue(settings.isProcessedPhoto)
        XCTAssertEqual(still.extent.width/still.extent.height,16.0/9.0,accuracy:0.01)
    }
    func testSmoothedZoomKeepsPinchAnchorFixedAcrossTransition() throws {
        let renderer = try makeRenderer(), processor = FrameProcessor(motion:MotionService(),renderer:renderer)
        var settings = CameraSettings(); settings.horizonLock = false; settings.zoomLock = false
        processor.configure(settings,front:false)
        let input = try buffer(pattern(width:360,height:640),renderer:renderer)
        let first = try processor.process(buffer:input,hostTime:1)
        let anchor = Point2(0.28,0.66)
        let source = first.plan.outputToSource(Point2(anchor.x*first.plan.output.width,(1-anchor.y)*first.plan.output.height))
        processor.setZoom(4,atUIKit:anchor)
        var previous = first.plan.zoom
        for frameIndex in 1...18 {
            let frame = try processor.process(buffer:input,hostTime:1+Double(frameIndex)/60)
            XCTAssertGreaterThanOrEqual(frame.plan.zoom,previous); XCTAssertLessThanOrEqual(frame.plan.zoom,4)
            let mapped = frame.plan.sourceToOutput(source)
            XCTAssertEqual(mapped.x,anchor.x*frame.plan.output.width,accuracy:0.02)
            XCTAssertEqual(mapped.y,(1-anchor.y)*frame.plan.output.height,accuracy:0.02)
            previous = frame.plan.zoom
        }
        XCTAssertEqual(previous,4,accuracy:0.01)
    }
    func testVideoRendererUsesRec709ColorSpace() throws {
        let renderer = try makeRenderer()
        let name = try XCTUnwrap(renderer.videoColorSpace.name)
        XCTAssertTrue(CFEqual(name,CGColorSpace.itur_709))
    }
    func testPreviewLayoutPreservesPortraitLandscapeAspectAndUIKitOrientation() throws {
        let bounds = CGSize(width:390,height:844)
        for image in [CGSize(width:1080,height:1920),CGSize(width:1920,height:1080)] {
            let rect = PreviewLayout.aspectFit(image:image,in:bounds)
            XCTAssertEqual(rect.midX,bounds.width/2,accuracy:0.001); XCTAssertEqual(rect.midY,bounds.height/2,accuracy:0.001)
            XCTAssertEqual(rect.width/rect.height,image.width/image.height,accuracy:0.0001)
            let ui = CGPoint(x:rect.minX+rect.width*0.25,y:rect.minY+rect.height*0.75)
            let normalized = try XCTUnwrap(PreviewLayout.normalizedUIKitPoint(ui,image:image,in:bounds))
            XCTAssertEqual(normalized.x,0.25,accuracy:0.0001); XCTAssertEqual(normalized.y,0.75,accuracy:0.0001)
            XCTAssertNil(PreviewLayout.normalizedUIKitPoint(CGPoint(x:-1,y:-1),image:image,in:bounds))
        }
    }
    func testProcessedPhotoEncodingPreservesMetadata() throws {
        let renderer = try makeRenderer()
        var settings = CameraSettings(); settings.customMetadataEnabled = true; settings.metadataAuthor = "Horizon Tester"; settings.metadataTitle = "Locked frame"
        let image = pattern(width:320,height:240)
        let encoded = try XCTUnwrap(CaptureMetadata.encodeProcessed(image,renderer:renderer,efficient:false,settings:settings))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.0 as CFData,nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source,0,nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata,nil,"tiff:Artist" as CFString) as String?,"Horizon Tester")
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata,nil,"photoshop:Headline" as CFString) as String?,"Locked frame")
    }

    func testPhotographicStyleApproximationChangesSavedPixelsDeterministically() throws {
        let renderer=try makeRenderer(), image=pattern(width:320,height:240)
        var settings=CameraSettings(); settings.photographicStyle = .richContrast; settings.styleIntensity=1; settings.styleTone=0.2; settings.styleWarmth = -0.25
        let styled=renderer.applyLook(image,settings:settings)
        XCTAssertEqual(styled.extent,image.extent)
        let p=Point2(80,60), original=pixel(image,p,renderer:renderer), changed=pixel(styled,p,renderer:renderer)
        XCTAssertNotEqual(Array(original.prefix(3)),Array(changed.prefix(3)))
    }

    func testComputationalBracketFusionProducesFiniteSameExtentImage() throws {
        let renderer=try makeRenderer(), base=pattern(width:320,height:240)
        let biases=ComputationalPhotoMode.autoHDR.exposureBiases
        let bracket=biases.map { base.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:$0]) }
        let fused=try XCTUnwrap(renderer.fuseBracket(bracket,mode:.autoHDR))
        XCTAssertEqual(fused.extent,base.extent)
        let value=pixel(fused,Point2(100,100),renderer:renderer)
        XCTAssertGreaterThan(value[3],250)
    }

    func testPortraitLightingUsesMatteForStageAndNaturalBlur() throws {
        let renderer=try makeRenderer(), image=pattern(width:320,height:240)
        let bounds=image.extent
        let mask=CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:160,height:240))
            .composited(over:CIImage(color:.black).cropped(to:bounds))
        let stage=renderer.portraitLighting(image,matte:mask,style:.stage,blurRadius:12)
        let subject=pixel(stage,Point2(80,120),renderer:renderer), background=pixel(stage,Point2(260,120),renderer:renderer)
        XCTAssertGreaterThan(Int(subject[0])+Int(subject[1])+Int(subject[2]),20)
        XCTAssertLessThan(Int(background[0])+Int(background[1])+Int(background[2]),20)
        let natural=renderer.portraitLighting(image,matte:mask,style:.natural,blurRadius:18)
        XCTAssertEqual(natural.extent,bounds)
    }

    func testPanoramaAssemblerCreatesWiderFeatheredImage() throws {
        let renderer=try makeRenderer(), assembler=PanoramaAssembler(renderer:renderer,horizontalFOVDegrees:70,feather:0.55)
        assembler.append(pattern(width:640,height:360),yaw:0)
        assembler.append(pattern(width:640,height:360).applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:0.03]),yaw:0.12)
        assembler.append(pattern(width:640,height:360).applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:-0.03]),yaw:0.24)
        let output=try assembler.finish()
        XCTAssertGreaterThan(output.extent.width,640); XCTAssertEqual(output.extent.height,360,accuracy:1)
        XCTAssertGreaterThan(pixel(output,Point2(10,100),renderer:renderer)[3],240)
    }

    func testDualCaptureLayoutsPutFrontAndBackPixelsInExpectedRegions() throws {
        let renderer=try makeRenderer()
        let back=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:200,height:300))
        let front=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:0,y:0,width:200,height:300))
        let split=DualCaptureComposer.compose(back:back,front:front,layout:.splitVertical,canvas:CGSize(width:400,height:300))
        XCTAssertGreaterThan(pixel(split,Point2(60,150),renderer:renderer)[0],240)
        XCTAssertGreaterThan(pixel(split,Point2(340,150),renderer:renderer)[2],240)
        let pip=DualCaptureComposer.compose(back:back,front:front,layout:.pictureInPicture,canvas:CGSize(width:400,height:600))
        XCTAssertGreaterThan(pixel(pip,Point2(200,200),renderer:renderer)[0],200)
        XCTAssertGreaterThan(pixel(pip,Point2(350,530),renderer:renderer)[2],180)
    }

    func testActionStrengthUsesMoreStabilizationReserveWithoutChangingOutputSize() throws {
        var low=CameraSettings(); low.mode = .video; low.horizonLock=false; let l0=low; low.actionStabilization=true; low.actionStrength=0; low.normalize(changedFrom:l0)
        var high=low; let h0=high; high.actionStrength=1; high.normalize(changedFrom:h0)
        XCTAssertGreaterThan(low.reserve,high.reserve)
        let source=Size2(2160,3840), output=low.outputSize
        let lowPlan=try CropGeometry.plan(source:source,output:output,angle:0,zoom:1,fullTurn:false,reserve:low.reserve)
        let highPlan=try CropGeometry.plan(source:source,output:output,angle:0,zoom:1,fullTurn:false,reserve:high.reserve)
        XCTAssertEqual(lowPlan.output,highPlan.output)
        XCTAssertLessThan(highPlan.sourceDetail.width,lowPlan.sourceDetail.width)
        XCTAssertLessThan(highPlan.sourceDetail.height,lowPlan.sourceDetail.height)
    }


    func testZoomLockFloatsCropToEdgeThenRecoversOnReversePan() throws {
        let renderer=try makeRenderer(), motion=MotionService(), processor=FrameProcessor(motion:motion,renderer:renderer)
        var settings=CameraSettings(); settings.mode = .video; settings.horizonLock=false; settings.zoomLock=true; settings.zoom=3; settings.videoFraming = .landscape; settings.resolution = .hd; settings.smartArtifactGuard=false
        processor.configure(settings,front:false,horizontalFOVDegrees:70)
        let input=try buffer(pattern(width:1280,height:720),renderer:renderer)
        motion.injectForTesting(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:0,rateX:0,rateY:0))
        let first=try processor.process(buffer:input,hostTime:1)
        let startX=first.plan.center.x
        var edgeFrame=first
        for index in 1...10 {
            let time=1+Double(index)*0.02
            motion.injectForTesting(MotionReading(time:time,gx:0,gy:-1,gz:0,rateZ:0,rateX:0,rateY:4))
            edgeFrame=try processor.process(buffer:input,hostTime:time)
        }
        XCTAssertLessThan(edgeFrame.plan.center.x,startX)
        XCTAssertTrue(edgeFrame.plan.wasClamped)
        let pinned=edgeFrame.plan.center.x
        let forwardTime=1.22
        motion.injectForTesting(MotionReading(time:forwardTime,gx:0,gy:-1,gz:0,rateZ:0,rateX:0,rateY:4))
        let stillPinned=try processor.process(buffer:input,hostTime:forwardTime)
        XCTAssertEqual(stillPinned.plan.center.x,pinned,accuracy:0.5)
        let reverseTime=1.24
        motion.injectForTesting(MotionReading(time:reverseTime,gx:0,gy:-1,gz:0,rateZ:0,rateX:0,rateY:-4))
        let reversing=try processor.process(buffer:input,hostTime:reverseTime)
        XCTAssertGreaterThan(reversing.plan.center.x,pinned+1)
        XCTAssertEqual(reversing.target,Point2(0.5,0.5))
    }

    func testActionAndArtifactGuardAffectRecordingPlanNotLivePreviewPlan() throws {
        let renderer=try makeRenderer(), motion=MotionService(), processor=FrameProcessor(motion:motion,renderer:renderer)
        var settings=CameraSettings(); settings.mode = .video; settings.horizonLock=false; settings.zoomLock=false; settings.actionStabilization=true; settings.actionStrength=0.8; settings.videoFraming = .landscape; settings.resolution = .hd; settings.smartArtifactGuard=true
        processor.configure(settings,front:false,horizontalFOVDegrees:70)
        let input=try buffer(pattern(width:1280,height:720),renderer:renderer)
        motion.injectForTesting(MotionReading(time:1,gx:1,gy:0,gz:0,rateZ:0,rateX:0,rateY:0))
        _=try processor.process(buffer:input,hostTime:1)
        motion.injectForTesting(MotionReading(time:1.02,gx:1,gy:0,gz:0,rateZ:0.2,rateX:1.5,rateY:2.0))
        let frame=try processor.process(buffer:input,hostTime:1.02)
        XCTAssertEqual(frame.plan.center.x,640,accuracy:1.0)
        XCTAssertEqual(frame.plan.center.y,360,accuracy:1.0)
        XCTAssertNotEqual(frame.recordingPlan.center,frame.plan.center)
        XCTAssertEqual(frame.recordingPlan.angle,frame.plan.angle,accuracy:0.05)
        XCTAssertLessThan(frame.recordingPlan.sourceDetail.width,frame.plan.sourceDetail.width)
        XCTAssertEqual(frame.image.extent,frame.recordingImage.extent)
    }

    func testSmartArtifactGuardUsesSaferOutputCropWithLiveHorizonPreview() throws {
        let renderer=try makeRenderer(), motion=MotionService(), processor=FrameProcessor(motion:motion,renderer:renderer)
        var settings=CameraSettings(); settings.mode = .video; settings.horizonLock=true; settings.smartArtifactGuard=true; settings.videoFraming = .landscape; settings.resolution = .hd
        processor.configure(settings,front:false,horizontalFOVDegrees:70)
        let input=try buffer(pattern(width:1280,height:720),renderer:renderer)
        motion.injectForTesting(MotionReading(time:2,gx:0.3,gy:-0.95,gz:0,rateZ:0,rateX:0,rateY:0))
        let frame=try processor.process(buffer:input,hostTime:2)
        XCTAssertEqual(frame.plan.angle,frame.recordingPlan.angle,accuracy:0.0001)
        XCTAssertGreaterThan(frame.recordingPlan.scale,frame.plan.scale)
        XCTAssertLessThan(frame.recordingPlan.sourceDetail.width,frame.plan.sourceDetail.width)
    }
    func testSpatialPhotoEncoderCreatesTwoImageStereoHEIC() throws {
        guard #available(iOS 18.0,*) else { throw XCTSkip("Spatial ImageIO metadata requires iOS 18") }
        let renderer=try makeRenderer(), leftCI=pattern(width:320,height:180)
        let eyeBounds=CGRect(x:0,y:0,width:320,height:180)
        let shifted=pattern(width:320,height:180).transformed(by:CGAffineTransform(translationX:2,y:0))
        let rightCI=shifted.composited(over:CIImage(color:.black).cropped(to:eyeBounds)).cropped(to:eyeBounds)
        let left=try XCTUnwrap(renderer.context.createCGImage(leftCI,from:leftCI.extent,format:.RGBA8,colorSpace:renderer.colorSpace))
        let right=try XCTUnwrap(renderer.context.createCGImage(rightCI,from:rightCI.extent,format:.RGBA8,colorSpace:renderer.colorSpace))
        let data=try SpatialPhotoEncoder.encode(left:left,right:right,commonFOV:70,rightPosition:[0.025,0,0],rightRotation:[1,0,0,0,1,0,0,0,1],settings:CameraSettings())
        let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil)); XCTAssertEqual(CGImageSourceGetCount(source),2)
        let container=try XCTUnwrap(CGImageSourceCopyProperties(source,nil) as? [CFString:Any])
        let groups=try XCTUnwrap(container[kCGImagePropertyGroups] as? [[CFString:Any]])
        let stereo=try XCTUnwrap(groups.first { ($0[kCGImagePropertyGroupType] as? String) == (kCGImagePropertyGroupTypeStereoPair as String) })
        XCTAssertEqual(stereo[kCGImagePropertyGroupImageIndexLeft] as? Int,0)
        XCTAssertEqual(stereo[kCGImagePropertyGroupImageIndexRight] as? Int,1)
        XCTAssertEqual(stereo[kCGImagePropertyGroupImageDisparityAdjustment] as? Int,0)
        let lp=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        let rp=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,1,nil) as? [CFString:Any])
        let lh=try XCTUnwrap(lp[kCGImagePropertyHEIFDictionary] as? [CFString:Any])
        let rh=try XCTUnwrap(rp[kCGImagePropertyHEIFDictionary] as? [CFString:Any])
        let le=try XCTUnwrap(lh[kIIOMetadata_CameraExtrinsicsKey] as? [CFString:Any])
        let re=try XCTUnwrap(rh[kIIOMetadata_CameraExtrinsicsKey] as? [CFString:Any])
        let leftPosition=try XCTUnwrap(le[kIIOCameraExtrinsics_Position] as? [NSNumber])
        let rightPosition=try XCTUnwrap(re[kIIOCameraExtrinsics_Position] as? [NSNumber])
        XCTAssertEqual(try XCTUnwrap(leftPosition.first).doubleValue,0,accuracy:0.0001)
        XCTAssertEqual(try XCTUnwrap(rightPosition.first).doubleValue,0.025,accuracy:0.0001)
    }

}
