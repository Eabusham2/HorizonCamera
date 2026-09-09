import AVFoundation
import CoreImage
import AudioToolbox

/// Frame-queue confined. The exact processed CIImage shown by the viewfinder
/// is rendered into the writer's pixel-buffer pool, not an unrelated raw stream.
final class MovieRecorder {
    let url: URL
    let settings: CameraSettings
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let renderer: ImageRenderer
    private var timeline: RecordingTimeline
    private var finishing = false
    private(set) var duration = 0.0
    private(set) var droppedFrames = 0
    private(set) var audioDrops = 0
    private(set) var writtenFrames = 0
    init(url: URL, settings: CameraSettings, renderer: ImageRenderer, microphoneAvailable: Bool) throws {
        self.url = url; self.settings = settings; self.renderer = renderer
        timeline = RecordingTimeline(cadence: settings.cadence)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = NativeMovieController.movieMetadata(settings)
        let size = settings.outputSize
        let fps = settings.mode == .slowMotion || settings.mode == .timeLapse ? 30 : settings.fps
        let bitrate = Int(size.width*size.height*Double(fps)*0.13)
        var output: [String: Any] = [AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps*2]]
        if !writer.canApply(outputSettings: output, forMediaType: .video) {
            output[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            throw CameraFailure.message("This device cannot encode the chosen video format.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CameraFailure.message("Cannot create the video recording track.") }
        writer.add(video)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        if settings.audio && settings.cadence.recordsAudio && microphoneAvailable {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CameraFailure.message("Cannot create the microphone track.") }
            writer.add(input); audio = input
        } else { audio = nil }
        writer.shouldOptimizeForNetworkUse = true
    }
    func appendVideo(_ image: CIImage, sourcePTS: CMTime) throws {
        guard !finishing else { return }
        if writer.status == .unknown {
            guard writer.startWriting() else { throw writer.error ?? CameraFailure.message("Video recording could not start.") }
            writer.startSession(atSourceTime: .zero)
        }
        guard writer.status == .writing else { throw writer.error ?? CameraFailure.message("The video encoder stopped.") }
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
        guard let pool = adaptor.pixelBufferPool else { throw CameraFailure.message("The video encoder has no pixel buffer pool.") }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &buffer)
        if result == kCVReturnWouldExceedAllocationThreshold { droppedFrames += 1; return }
        guard result == kCVReturnSuccess, let buffer else { throw CameraFailure.message("Cannot allocate a recording frame (\(result)).") }
        guard let seconds = timeline.accept(sourceTime: sourcePTS.seconds) else { return }
        renderer.renderVideo(image, into: buffer)
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60000)) else {
            throw writer.error ?? CameraFailure.message("The encoder rejected a video frame.")
        }
        duration = seconds; writtenFrames += 1
    }
    func appendAudio(_ buffer: CMSampleBuffer) throws {
        guard !finishing, let audio, writer.status == .writing, let origin = timeline.origin,
              timeline.audioTime(sourceTime: CMSampleBufferGetPresentationTimeStamp(buffer).seconds) != nil else { return }
        guard audio.isReadyForMoreMediaData else { audioDrops += 1; return }
        var count: CMItemCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { audioDrops += 1; return }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        status = timings.withUnsafeMutableBufferPointer { ptr in
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: ptr.baseAddress, entriesNeededOut: &count)
        }
        guard status == noErr else { audioDrops += 1; return }
        let offset = CMTime(seconds: origin, preferredTimescale: 60000)
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset) }
        }
        var copy: CMSampleBuffer?
        status = timings.withUnsafeBufferPointer { ptr in
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                sampleTimingEntryCount: count, sampleTimingArray: ptr.baseAddress!, sampleBufferOut: &copy)
        }
        guard status == noErr, let copy else { audioDrops += 1; return }
        guard audio.append(copy) else { throw writer.error ?? CameraFailure.message("The encoder rejected microphone audio.") }
    }
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finishing else { return }; finishing = true
        guard writer.status == .writing, writtenFrames > 0 else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
            completion(.failure(writer.error ?? CameraFailure.message("No video frames were captured. Nothing was saved."))); return
        }
        video.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed { completion(.success(url)) }
            else { completion(.failure(writer.error ?? CameraFailure.message("Could not finish the video file."))) }
        }
    }
}
