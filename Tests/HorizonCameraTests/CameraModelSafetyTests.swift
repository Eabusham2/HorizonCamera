import XCTest
@testable import HorizonCamera

final class CameraModelSafetyTests: XCTestCase {
    private func photoSettings() -> CameraSettings {
        var settings = CameraSettings()
        settings.mode = .photo
        settings.horizonLock = false
        settings.zoomLock = false
        return settings
    }

    func testQuickTakeChoosesLargestResolutionThatFitsBothSourceDimensions() throws {
        let sources: [(Size2, Resolution)] = [
            (Size2(720, 1280), .hd),
            (Size2(1080, 1920), .fullHD),
            (Size2(1440, 1920), .fullHD),
            (Size2(2160, 3840), .ultraHD),
            (Size2(1080, 3840), .fullHD),
            (Size2(2160, 1920), .fullHD)
        ]
        for (source, expected) in sources {
            let quick = try XCTUnwrap(CameraModel.quickTakeSettings(from: photoSettings(), sourceSize: source))
            XCTAssertEqual(quick.resolution, expected)
            XCTAssertLessThanOrEqual(quick.outputSize.width, source.width)
            XCTAssertLessThanOrEqual(quick.outputSize.height, source.height)
            XCTAssertEqual(quick.videoFraming, .portrait)
        }
    }

    func testQuickTakePreservesPhotoStreamFrameRateInsteadOfAssumingThirty() throws {
        for rate in [23.976, 24, 25, 30, 59.94, 60, 120] {
            var photo = photoSettings()
            photo.fps = rate
            let quick = try XCTUnwrap(CameraModel.quickTakeSettings(from: photo, sourceSize: Size2(1080, 1920)))
            XCTAssertEqual(quick.fps, rate, accuracy: 0.000001)
            XCTAssertEqual(quick.captureFPS, rate, accuracy: 0.000001)
        }
    }

    func testQuickTakeBuildsVideoOverrideForEitherNativePhotoChoice() throws {
        for raw in [false, true] {
            var photo = photoSettings()
            photo.raw = raw
            photo.livePhoto = !raw
            photo.preferProRAW = false
            photo.timer = 5
            let quick = try XCTUnwrap(CameraModel.quickTakeSettings(from: photo, sourceSize: Size2(1080, 1920)))
            XCTAssertEqual(quick.mode, .video)
            XCTAssertFalse(quick.raw)
            XCTAssertFalse(quick.livePhoto)
            XCTAssertEqual(quick.timer, 0)
        }
    }

    func testQuickTakeRejectsInsufficientOrInvalidSourceInsteadOfUpscaling() {
        for source in [Size2(640, 480), Size2(3840, 720), Size2(0, 1920), Size2(.infinity, 1920), Size2(1080, .nan)] {
            XCTAssertNil(CameraModel.quickTakeSettings(from: photoSettings(), sourceSize: source))
        }
        var invalid = photoSettings()
        invalid.fps = 0
        XCTAssertNil(CameraModel.quickTakeSettings(from: invalid, sourceSize: Size2(1080, 1920)))
    }
}
