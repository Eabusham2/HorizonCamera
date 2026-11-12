import XCTest
import AVFoundation
import CoreImage
@testable import HorizonCamera

final class MovieSafetyTests: XCTestCase {
    private func settings(codec: CodecChoice = .compatible) -> CameraSettings {
        var settings = CameraSettings()
        settings.mode = .video
        settings.codec = codec
        settings.resolution = .hd
        settings.videoFraming = .landscape
        settings.horizonLock = false
        settings.audio = false
        return settings
    }

    private func newURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    private func finishedMovie(codec: CodecChoice = .compatible) async throws -> (MovieRecorder, URL) {
        let renderer = try XCTUnwrap(ImageRenderer(), "The simulator must provide Metal.")
        let settings = settings(codec: codec), url = newURL()
        let recorder = try MovieRecorder(url: url, settings: settings, renderer: renderer, microphoneAvailable: false)
        do {
            let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.8))
                .cropped(to: CGRect(x: 0, y: 0, width: settings.outputSize.width, height: settings.outputSize.height))
            for index in 0..<8 {
                try recorder.appendVideo(image, sourcePTS: CMTime(seconds: 100 + Double(index)/30, preferredTimescale: 60000))
                try await Task.sleep(for: .milliseconds(35))
            }
            let finished: URL = try await withCheckedThrowingContinuation { continuation in
                recorder.finish { continuation.resume(with: $0) }
            }
            XCTAssertEqual(finished, url)
            XCTAssertGreaterThan(recorder.writtenFrames, 1)
            return (recorder, url)
        } catch {
            recorder.cancel()
            throw error
        }
    }

    func testUnsupportedHEVCIsRejectedWithoutTryingH264() {
        var attempted: [AVVideoCodecType] = []
        XCTAssertThrowsError(try MovieRecorder.videoOutputSettings(settings(codec: .efficient), canApply: { output in
            let codec = output[AVVideoCodecKey] as? AVVideoCodecType
            if let codec { attempted.append(codec) }
            // A fallback would succeed here, which must not be allowed.
            return codec == .h264
        }))
        XCTAssertEqual(attempted, [.hevc])
    }

    func testSavedCustomMoviesUseTheirRequestedCodecs() async throws {
        for codec: CodecChoice in [.compatible, .efficient] {
            let (_, url) = try await finishedMovie(codec: codec)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format),
                codec == .efficient ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264)
        }
    }

    func testCancellingUnfinishedMovieRemovesItsOutputAndStopsAppending() throws {
        let renderer = try XCTUnwrap(ImageRenderer(), "The simulator must provide Metal.")
        let url = newURL(), settings = settings()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try MovieRecorder(url: url, settings: settings, renderer: renderer, microphoneAvailable: false)
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: settings.outputSize.width, height: settings.outputSize.height))
        try recorder.appendVideo(image, sourcePTS: CMTime(seconds: 1, preferredTimescale: 60000))
        XCTAssertEqual(recorder.writtenFrames, 1)
        recorder.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try recorder.appendVideo(image, sourcePTS: CMTime(seconds: 2, preferredTimescale: 60000))
        XCTAssertEqual(recorder.writtenFrames, 1)
    }

    func testFailedInitializationDoesNotDeleteAnExistingFile() throws {
        let renderer = try XCTUnwrap(ImageRenderer(), "The simulator must provide Metal.")
        let url = newURL(), original = Data("existing movie resource".utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)
        XCTAssertThrowsError(try MovieRecorder(url: url, settings: settings(), renderer: renderer, microphoneAvailable: false))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFinishedNativeRecordingSurvivesSuccessfulCompletionWarningAndCancel() async throws {
        let (recorder, url) = try await finishedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        recorder.cancel()
        XCTAssertEqual(try Data(contentsOf: url), original)
        let warning = NSError(domain: AVFoundationErrorDomain, code: -1,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        let result = await NativeMovieController.finalizeRecording(at: url, error: warning)
        XCTAssertEqual(try result.get(), url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNativeRecordingFailureAndInvalidResourcesAreRemoved() async throws {
        let failure = NSError(domain: AVFoundationErrorDomain, code: -1,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: false])
        let warning = NSError(domain: AVFoundationErrorDomain, code: -1,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        let errors: [Error?] = [nil, failure, warning]
        for error in errors {
            let url = newURL()
            defer { try? FileManager.default.removeItem(at: url) }
            try Data("unfinished movie bytes".utf8).write(to: url)
            let result = await NativeMovieController.finalizeRecording(at: url, error: error)
            if case .success = result { XCTFail("An invalid movie must not be saved, even with a success flag.") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let missing = newURL()
        let result = await NativeMovieController.finalizeRecording(at: missing, error: nil)
        if case .success = result { XCTFail("A missing recording must not be saved.") }
    }
}
