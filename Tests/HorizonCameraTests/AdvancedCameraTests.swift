import XCTest
import AVFoundation
import ImageIO
import CoreLocation
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
    func testPortraitModeForcesNativeDepthSafeSettings() {
        var s = CameraSettings(); let old = s
        s.mode = .portrait; s.horizonLock = true; s.zoomLock = true; s.raw = true; s.livePhoto = true; s.filter = .vivid
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.mode.isPhotoMode); XCTAssertFalse(s.mode.isMovie)
        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)
        XCTAssertFalse(s.horizonLock); XCTAssertFalse(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)
        XCTAssertEqual(s.filter,.original); XCTAssertEqual(s.photoFraming,.classic)
    }
    func testConstantColorForcesCompatibleFlashAndDisablesRawLive() {
        var s = CameraSettings(); s.mode = .photo; s.horizonLock = false
        let old = s; s.constantColor = true; s.raw = true; s.livePhoto = true; s.flash = .off
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.constantColor); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto); XCTAssertEqual(s.flash,.auto)
    }
    func testNativeMovieFramingUsesRepresentableOrientation() {
        var s = CameraSettings(); let old = s
        s.mode = .cinematic; s.videoFraming = .square
        s.normalize(changedFrom: old)
        XCTAssertEqual(s.videoFraming,.portrait)
    }
    func testPhotoMetadataContainsStandardTIFFAndIPTCFields() throws {
        var s = CameraSettings(); s.metadataTitle = "Title"; s.metadataAuthor = "Eyad"; s.metadataCopyright = "Copyright"; s.metadataDescription = "Description"; s.metadataKeywords = "camera, horizon"
        let metadata = CaptureMetadata.photo(s)
        let tiff = try XCTUnwrap(metadata[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"Eyad")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware as String] as? String,"HorizonCamera")
        let iptc = try XCTUnwrap(metadata[kCGImagePropertyIPTCDictionary as String] as? [String:Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCObjectName as String] as? String,"Title")
        XCTAssertEqual((iptc[kCGImagePropertyIPTCKeywords as String] as? [String]) ?? [],["camera","horizon"])
    }

    func testSourceExifSurvivesCustomMetadataMerge() throws {
        var settings = CameraSettings(); settings.metadataAuthor = "New Author"
        let originalExif: [String:Any] = [kCGImagePropertyExifExposureTime as String: 0.01]
        let metadata = CaptureMetadata.photo(settings,base:[kCGImagePropertyExifDictionary as String:originalExif])
        let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary as String] as? [String:Any])
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime as String] as? Double,0.01)
    }
    func testISO6709AndGPSMetadataFormatting() {
        let location = CLLocation(coordinate:CLLocationCoordinate2D(latitude:30.2672,longitude:-97.7431),altitude:155,
            horizontalAccuracy:6,verticalAccuracy:8,timestamp:Date())
        let iso = CaptureLocation.iso6709(location)
        XCTAssertTrue(iso.hasPrefix("+30.267200-97.743100+155.0"))
        let gps = CaptureLocation.gpsDictionary(location)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String,"N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef as String] as? String,"W")
    }
    func testNativeMovieMetadataIncludesEditableFields() {
        var settings = CameraSettings(); settings.metadataTitle = "Test Title"; settings.metadataAuthor = "Test Author"; settings.metadataKeywords = "one,two"
        let metadata = NativeMovieController.movieMetadata(settings)
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataTitle && $0.stringValue == "Test Title" })
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataAuthor && $0.stringValue == "Test Author" })
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataSoftware })
    }

    func testOldSettingsJSONMigratesWithoutLosingExistingValues() throws {
        let old = #"{"mode":"VIDEO","zoom":2.5,"grid":false,"horizonLock":false}"#.data(using:.utf8)!
        let migrated = try XCTUnwrap(CameraModel.decodeSettingsMigrating(old))
        XCTAssertEqual(migrated.mode,.video); XCTAssertEqual(migrated.zoom,2.5); XCTAssertFalse(migrated.grid); XCTAssertFalse(migrated.horizonLock)
        XCTAssertTrue(migrated.scanQRCodes); XCTAssertTrue(migrated.showDetectedText); XCTAssertTrue(migrated.lensCleaningHints)
    }
    func testNewDetectionAndSwitchingSettingsRoundTrip() throws {
        var settings = CameraSettings(); settings.lockCameraSwitching = true; settings.centerStage = true; settings.smartFraming = true
        settings.photoResolutionMP = 24; settings.scanQRCodes = false; settings.showDetectedText = false; settings.lensCleaningHints = false
        let decoded = try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(decoded,settings)
    }

    func testApproximationModesNormalizeWithoutPretendingNativePipelines() {
        var action=CameraSettings(); let a0=action
        action.mode = .video; action.actionStabilization = true; action.actionNativeAssist = true; action.actionStrength = 0.9
        action.zoomLock=true; action.colorProfile = .hdrHLG; action.codec = .proRes422; action.audioMode = .stereo
        action.normalize(changedFrom:a0)
        XCTAssertTrue(action.actionStabilization); XCTAssertTrue(action.actionNativeAssist); XCTAssertFalse(action.zoomLock)
        XCTAssertEqual(action.codec,.efficient); XCTAssertEqual(action.colorProfile,.sdr); XCTAssertEqual(action.audioMode,.mono)
        XCTAssertEqual(action.actionStrength,0.9,accuracy:0.001); XCTAssertLessThan(action.reserve,0.86)

        var legacy=CameraSettings(); let legacyOld=legacy; legacy.mode = .action; legacy.normalize(changedFrom:legacyOld)
        XCTAssertEqual(legacy.mode,.video); XCTAssertTrue(legacy.actionStabilization); XCTAssertTrue(legacy.horizonLock)

        var dual=CameraSettings(); let d0=dual; dual.mode = .dualCapture; dual.resolution = .ultraHD; dual.audioMode = .spatial
        dual.normalize(changedFrom:d0)
        XCTAssertEqual(dual.fps,30); XCTAssertEqual(dual.resolution,.fullHD); XCTAssertEqual(dual.audioMode,.mono)
        XCTAssertTrue(dual.mode.isStandaloneCaptureMode); XCTAssertTrue(dual.mode.isMovie)

        var pano=CameraSettings(); let p0=pano; pano.mode = .panorama; pano.raw=true; pano.livePhoto=true; pano.computationalPhoto = .night
        pano.normalize(changedFrom:p0)
        XCTAssertFalse(pano.raw); XCTAssertFalse(pano.livePhoto); XCTAssertEqual(pano.computationalPhoto,.off); XCTAssertTrue(pano.mode.isPhotoMode)
    }

    func testComputationalPhotoDisablesIncompatibleNativeExtras() {
        var s=CameraSettings(); s.mode = .photo; s.horizonLock=false; let old=s
        s.computationalPhoto = .autoHDR; s.raw=true; s.livePhoto=true; s.constantColor=true; s.flash = .on; s.depthData=true
        s.normalize(changedFrom:old)
        XCTAssertTrue(s.usesBracketedPhotoPipeline); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto); XCTAssertFalse(s.constantColor)
        XCTAssertFalse(s.depthData); XCTAssertEqual(s.flash,.off); XCTAssertTrue(s.isProcessedPhoto)
    }

    func testApproximationSettingsRoundTripThroughCodableAndMigrationDefaults() throws {
        var s=CameraSettings(); s.photographicStyle = .richContrast; s.styleIntensity=0.7; s.portraitLighting = .contour
        s.actionStabilization = true; s.actionNativeAssist = false; s.actionStrength=0.9; s.dualCaptureLayout = .splitVertical
        let decoded=try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(s)); XCTAssertEqual(decoded,s)
        let old = #"{"mode":"PHOTO","grid":false}"#.data(using:.utf8)!
        let migrated=try XCTUnwrap(CameraModel.decodeSettingsMigrating(old))
        XCTAssertEqual(migrated.photographicStyle,.standard); XCTAssertEqual(migrated.computationalPhoto,.off); XCTAssertEqual(migrated.portraitLighting,.natural)
    }

    func testMotionHistoryInterpolatesThreeAxisGyroAndYawAcrossWrap() throws {
        var history=MotionHistory()
        history.append(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:1,rateX:2,rateY:3,yaw:Double.pi-0.1))
        history.append(MotionReading(time:2,gx:0,gy:-1,gz:0,rateZ:3,rateX:4,rateY:5,yaw:-Double.pi+0.1))
        let m=try XCTUnwrap(history.sample(at:1.5))
        XCTAssertEqual(m.rateX,3,accuracy:0.001); XCTAssertEqual(m.rateY,4,accuracy:0.001); XCTAssertEqual(m.rateZ,2,accuracy:0.001)
        XCTAssertLessThan(abs(AngleMath.wrap(m.yaw)-Double.pi),0.11)
    }

    func testManualFocusAFAELockAndExposureSettingsRoundTrip() throws {
        var settings=CameraSettings()
        settings.manualFocus=true; settings.lensPosition=0.23; settings.aeafLock=true
        settings.focusRange = .near; settings.smoothAutofocus=false; settings.faceDrivenAutofocus=false
        settings.exposureEV=1.2; settings.manualExposure=false
        let decoded=try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(decoded,settings)
        XCTAssertTrue(decoded.manualFocus); XCTAssertEqual(decoded.lensPosition,0.23,accuracy:0.001)
        XCTAssertTrue(decoded.aeafLock); XCTAssertEqual(decoded.focusRange,.near); XCTAssertEqual(decoded.exposureEV,1.2,accuracy:0.001)
    }

    func testActionTickDefaultsMigrationAndLiveStrengthPolicy() throws {
        let defaults=CameraSettings()
        XCTAssertFalse(defaults.actionStabilization); XCTAssertTrue(defaults.actionNativeAssist); XCTAssertEqual(defaults.actionStrength,0.75,accuracy:0.001)
        XCTAssertFalse(CameraMode.visibleCases.contains(.action))

        let legacyJSON = #"{"mode":"ACTION","actionStrength":0.6,"horizonLock":true}"#.data(using:.utf8)!
        let migrated=try XCTUnwrap(CameraModel.decodeSettingsMigrating(legacyJSON))
        XCTAssertEqual(migrated.mode,.video); XCTAssertTrue(migrated.actionStabilization); XCTAssertTrue(migrated.horizonLock)
        XCTAssertEqual(migrated.actionStrength,0.6,accuracy:0.001)

        var action=CameraSettings(); action.horizonLock=false; let before=action; action.actionStabilization=true; action.normalize(changedFrom:before)
        var adjusted=action; let actionBefore=adjusted; adjusted.actionStrength=0.95; adjusted.normalize(changedFrom:actionBefore)
        XCTAssertFalse(adjusted.requiresCaptureReconfiguration(comparedTo:action))
        var nativeToggle=adjusted; nativeToggle.actionNativeAssist.toggle()
        XCTAssertTrue(nativeToggle.requiresCaptureReconfiguration(comparedTo:adjusted))
    }

    func testDolbyVisionProfileForcesHEVCNativePipeline() {
        var settings=CameraSettings(); let old=settings; settings.mode = .video; settings.colorProfile = .dolbyVision84; settings.codec = .compatible
        settings.normalize(changedFrom:old)
        XCTAssertEqual(settings.codec,.efficient); XCTAssertTrue(settings.usesNativeMoviePipeline); XCTAssertTrue(settings.colorProfile.isHDR)
    }

}
