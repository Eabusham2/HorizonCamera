import XCTest
import AVFoundation
@testable import HorizonCamera

final class AdvancedCameraTests: XCTestCase {
    func testNativeMovieModesDisableCustomPixelTransforms() {
        var s = CameraSettings()
        let old = s
        s.horizonLock = true; s.zoomLock = true; s.filter = .vivid; s.mode = .cinematic
        s.normalize(changedFrom: old)
        XCTAssertFalse(s.horizonLock); XCTAssertFalse(s.zoomLock); XCTAssertEqual(s.filter, .original)
        XCTAssertTrue(s.usesNativeMoviePipeline)
    }
    func testProResAndLogForceNativePipeline() {
        var s = CameraSettings(); let old = s
        s.codec = .proRes422; s.colorProfile = .appleLog
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.usesNativeMoviePipeline)
        XCTAssertFalse(s.horizonLock)
    }
    func testExpandedResolutionAndFrameRateModel() {
        XCTAssertEqual(Resolution.hd.longEdge, 1280)
        var s = CameraSettings(); s.mode = .slowMotion; s.slowMotionFPS = 240; s.resolution = .hd
        XCTAssertEqual(s.captureFPS, 240)
        XCTAssertEqual(s.outputSize.width.rounded(), 720)
        XCTAssertEqual(s.outputSize.height.rounded(), 1280)
    }
    func testPhotoNativeExtrasRemainMutuallyExclusive() {
        var s = CameraSettings(); s.mode = .photo; s.horizonLock = false
        let old = s; s.raw = true; s.livePhoto = true; s.normalize(changedFrom: old)
        XCTAssertTrue(s.raw); XCTAssertFalse(s.livePhoto)
    }
    func testMetadataFieldsRoundTripThroughSettingsCodable() throws {
        var s = CameraSettings(); s.metadataAuthor = "Author"; s.metadataCopyright = "Copyright"; s.metadataDescription = "Description"
        let decoded = try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
}
