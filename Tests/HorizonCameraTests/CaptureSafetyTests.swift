import XCTest
import AVFoundation
import Foundation
@testable import HorizonCamera

final class CaptureSafetyTests: XCTestCase {
    private let bayerFormat: OSType = 101
    private let proRAWFormat: OSType = 202

    private func photoSettings(raw: Bool = false, live: Bool = false) -> CameraSettings {
        var settings = CameraSettings()
        settings.mode = .photo
        settings.raw = raw
        settings.livePhoto = live
        return settings
    }

    private func plan(_ settings: CameraSettings, codecs: [AVVideoCodecType] = [.hevc, .jpeg],
                      formats: [OSType] = [], liveEnabled: Bool = true,
                      liveSuspended: Bool = false) throws -> PhotoCapturePlan {
        try PhotoCapturePlan(settings: settings, availableCodecs: codecs, rawFormats: formats,
            livePhotoEnabled: liveEnabled, livePhotoSuspended: liveSuspended,
            isAppleProRAW: { $0 == self.proRAWFormat }, isBayerRAW: { $0 == self.bayerFormat })
    }

    // These sentinels exercise resource policy, not camera encoding or image decoding.
    private func packet(_ settings: CameraSettings, data: Data = Data([1]),
                        raw: Data? = nil, movie: URL? = nil) -> PhotoPacket {
        PhotoPacket(data: data, rawData: raw, liveMovie: movie, timestamp: .zero, settings: settings,
            hasDepthData: false, hasPortraitEffectsMatte: false, hasCalibrationData: false,
            depthData: nil, portraitEffectsMatte: nil)
    }

    func testRAWRequestRejectsMissingUnknownAndWrongSubtype() {
        for prefersProRAW in [false, true] {
            var settings = photoSettings(raw: true)
            settings.preferProRAW = prefersProRAW
            let wrongFormat = prefersProRAW ? bayerFormat : proRAWFormat
            for formats: [OSType] in [[], [999], [wrongFormat], [999, wrongFormat]] {
                XCTAssertThrowsError(try plan(settings, formats: formats),
                    "Requested RAW type must not fall back: ProRAW=\(prefersProRAW), formats=\(formats)")
            }
        }
    }

    func testRAWRequestSelectsRequestedSubtypeRegardlessOfOrdering() throws {
        for formats in [[bayerFormat, proRAWFormat], [proRAWFormat, bayerFormat]] {
            for prefersProRAW in [false, true] {
                var settings = photoSettings(raw: true)
                settings.preferProRAW = prefersProRAW
                let result = try plan(settings, formats: formats)
                XCTAssertEqual(result.rawPixelFormat, prefersProRAW ? proRAWFormat : bayerFormat)
                XCTAssertEqual(result.codec, .hevc)
                XCTAssertFalse(result.livePhoto)
            }
        }
    }

    func testBayerUsesSpeedAndProRAWRetainsRequestedQuality() throws {
        for quality in PhotoQualityChoice.allCases {
            var settings = photoSettings(raw: true)
            settings.photoQuality = quality
            settings.preferProRAW = false
            XCTAssertEqual(try plan(settings, formats: [bayerFormat]).qualityPrioritization, .speed)
            settings.preferProRAW = true
            XCTAssertEqual(try plan(settings, formats: [proRAWFormat]).qualityPrioritization, quality.avValue)
            settings.raw = false
            XCTAssertEqual(try plan(settings).qualityPrioritization, quality.avValue)
        }
    }

    func testPhotoEncodingNeverSubstitutesHEIFOrJPEG() throws {
        var settings = photoSettings()
        settings.codec = .efficient
        XCTAssertThrowsError(try plan(settings, codecs: [.jpeg]))
        XCTAssertThrowsError(try plan(settings, codecs: []))
        XCTAssertEqual(try plan(settings, codecs: [.hevc]).codec, .hevc)

        settings.codec = .compatible
        XCTAssertThrowsError(try plan(settings, codecs: [.hevc]))
        XCTAssertThrowsError(try plan(settings, codecs: []))
        let jpeg = try plan(settings, codecs: [.jpeg])
        XCTAssertEqual(jpeg.codec, .jpeg)
        XCTAssertNil(jpeg.rawPixelFormat)
        XCTAssertFalse(jpeg.livePhoto)
    }

    func testLiveRequestRequiresEnabledAndUnsuspendedOutput() throws {
        let settings = photoSettings(live: true)
        for (enabled, suspended) in [(false, false), (true, true), (false, true)] {
            XCTAssertThrowsError(try plan(settings, liveEnabled: enabled, liveSuspended: suspended))
        }
        let result = try plan(settings, liveEnabled: true, liveSuspended: false)
        XCTAssertTrue(result.livePhoto)
        XCTAssertNil(result.rawPixelFormat)

        let ordinary = try plan(photoSettings(), liveEnabled: false, liveSuspended: true)
        XCTAssertFalse(ordinary.livePhoto)
    }

    func testNativeRequestsRejectWrongModeAndCombinedRAWLive() {
        for mode: CameraMode in [.video, .portrait, .panorama, .spatialPhoto] {
            for isRAW in [false, true] {
                var settings = photoSettings(raw: isRAW, live: !isRAW)
                settings.mode = mode
                XCTAssertThrowsError(try plan(settings, formats: [bayerFormat, proRAWFormat]))
            }
        }
        XCTAssertThrowsError(try plan(photoSettings(raw: true, live: true),
            formats: [bayerFormat, proRAWFormat]))
    }

    func testPhotoPacketRequiresRequestedRAWAndNonemptyImageData() {
        let settings = photoSettings(raw: true)
        XCTAssertThrowsError(try packet(settings).validate())
        XCTAssertThrowsError(try packet(settings, raw: Data()).validate())
        XCTAssertThrowsError(try packet(settings, data: Data(), raw: Data([2])).validate())
        XCTAssertNoThrow(try packet(settings, raw: Data([2])).validate())
        XCTAssertThrowsError(try packet(photoSettings(), raw: Data()).validate())
    }

    func testPhotoPacketRequiresCompletedNonemptyLiveMovieResource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = photoSettings(live: true)
        XCTAssertThrowsError(try packet(settings).validate())
        XCTAssertThrowsError(try packet(settings, movie: directory.appendingPathComponent("missing.mov")).validate())
        XCTAssertThrowsError(try packet(settings, movie: directory).validate())

        let empty = directory.appendingPathComponent("empty.mov")
        try Data().write(to: empty)
        XCTAssertThrowsError(try packet(settings, movie: empty).validate())

        let completed = directory.appendingPathComponent("completed.mov")
        try Data([3, 4, 5]).write(to: completed)
        XCTAssertNoThrow(try packet(settings, movie: completed).validate())
    }

    func testReceivedNativeResourcesBypassRenderingWithStaleSettings() {
        var settings = photoSettings()
        settings.horizonLock = true
        settings.zoomLock = true
        settings.zoom = 3
        settings.photoFraming = .square
        settings.filter = .vivid
        XCTAssertTrue(settings.isProcessedPhoto)
        XCTAssertTrue(packet(settings).requiresProcessing)
        XCTAssertFalse(packet(settings, raw: Data([2])).requiresProcessing)
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        XCTAssertFalse(packet(settings, movie: movie).requiresProcessing)

        settings.raw = true
        XCTAssertFalse(packet(settings).requiresProcessing)
        settings.raw = false
        settings.livePhoto = true
        XCTAssertFalse(packet(settings).requiresProcessing)
    }

    func testNativeChoiceSurvivesCustomTransformsAndConflictingEdits() {
        for isRAW in [false, true] {
            var previous = photoSettings()
            addCustomTransforms(to: &previous)
            var settings = previous
            settings.raw = isRAW
            settings.livePhoto = !isRAW
            settings.normalize(changedFrom: previous)
            assertNativeFraming(settings, raw: isRAW)

            previous = settings
            addCustomTransforms(to: &settings)
            settings.normalize(changedFrom: previous)
            assertNativeFraming(settings, raw: isRAW)
        }
    }

    func testLegacyLaunchPreservesNativeChoiceAndDisablesDeferredDelivery() throws {
        for isRAW in [false, true] {
            var legacy = photoSettings(raw: isRAW, live: !isRAW)
            legacy.preferProRAW = false
            legacy.autoDeferredPhotoDelivery = true
            addCustomTransforms(to: &legacy)
            let data = try JSONEncoder().encode(legacy)
            let decoded = try XCTUnwrap(CameraModel.decodeSettingsMigrating(data))
            let launched = CameraModel.preparedForLaunch(decoded)
            XCTAssertFalse(launched.autoDeferredPhotoDelivery)
            assertNativeFraming(launched, raw: isRAW)
            if isRAW { XCTAssertFalse(launched.preferProRAW) }
        }
    }

    func testSwitchingRAWSubtypeReconfiguresInBothDirections() {
        var bayer = photoSettings(raw: true)
        bayer.preferProRAW = false
        var proRAW = bayer
        proRAW.preferProRAW = true
        XCTAssertTrue(proRAW.requiresCaptureReconfiguration(comparedTo: bayer))
        XCTAssertTrue(bayer.requiresCaptureReconfiguration(comparedTo: proRAW))
        XCTAssertFalse(bayer.requiresCaptureReconfiguration(comparedTo: bayer))
    }

    func testStaleNativeSettingsCannotEnterBracketPipeline() {
        for mode: ComputationalPhotoMode in [.autoHDR, .night, .detailFusion] {
            var ordinary = photoSettings()
            ordinary.computationalPhoto = mode
            XCTAssertTrue(ordinary.usesBracketedPhotoPipeline)
            for isRAW in [false, true] {
                var native = ordinary
                native.raw = isRAW
                native.livePhoto = !isRAW
                // Deliberately omit normalization to test the capture-routing guard.
                XCTAssertFalse(native.usesBracketedPhotoPipeline)
                XCTAssertFalse(native.isProcessedPhoto)
            }
        }
    }

    private func addCustomTransforms(to settings: inout CameraSettings) {
        settings.horizonLock = true
        settings.zoomLock = true
        settings.zoom = 4
        settings.photoFraming = .square
        settings.filter = .vivid
        settings.photographicStyle = .vibrant
        settings.styleTone = 0.5
        settings.styleWarmth = -0.5
        settings.portraitLighting = .studio
        settings.computationalPhoto = .night
        settings.constantColor = true
        settings.centerStage = true
        settings.smartFraming = true
    }

    private func assertNativeFraming(_ settings: CameraSettings, raw: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(settings.raw, raw, file: file, line: line)
        XCTAssertEqual(settings.livePhoto, !raw, file: file, line: line)
        XCTAssertTrue(settings.preservesNativePhotoOriginals, file: file, line: line)
        XCTAssertFalse(settings.isProcessedPhoto, file: file, line: line)
        XCTAssertFalse(settings.horizonLock, file: file, line: line)
        XCTAssertFalse(settings.zoomLock, file: file, line: line)
        XCTAssertEqual(settings.zoom, 1, file: file, line: line)
        XCTAssertEqual(settings.photoFraming, .classic, file: file, line: line)
        XCTAssertEqual(settings.filter, .original, file: file, line: line)
        XCTAssertEqual(settings.photographicStyle, .standard, file: file, line: line)
        XCTAssertEqual(settings.styleTone, 0, file: file, line: line)
        XCTAssertEqual(settings.styleWarmth, 0, file: file, line: line)
        XCTAssertEqual(settings.portraitLighting, .natural, file: file, line: line)
        XCTAssertEqual(settings.computationalPhoto, .off, file: file, line: line)
        XCTAssertFalse(settings.constantColor, file: file, line: line)
        XCTAssertFalse(settings.centerStage, file: file, line: line)
        XCTAssertFalse(settings.smartFraming, file: file, line: line)
    }
}
