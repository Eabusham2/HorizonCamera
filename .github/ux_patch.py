from pathlib import Path
import re


def rep(path: str, old: str, new: str, *, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n < count:
        raise SystemExit(f"{path}: need {count} literal match(es), found {n}: {old!r}")
    p.write_text(s.replace(old, new, count))


def sub1(path: str, pattern: str, replacement: str, flags=0):
    p = Path(path)
    s = p.read_text()
    out, n = re.subn(pattern, replacement, s, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"{path}: expected one regex match, found {n}: {pattern}")
    p.write_text(out)


# --- Defaults and compatibility policy -------------------------------------------------
rep('App/CameraSettings.swift', '    var showOverview = false\n',
    '    var showOverview = true\n    var showStats = false\n')
rep('App/CameraSettings.swift', '    var stabilization: StabilizationChoice = .auto\n',
    '    var stabilization: StabilizationChoice = .standard\n')
rep('App/CameraSettings.swift', '    var includeLocationMetadata = false\n',
    '    var includeLocationMetadata = true\n')

sub1('App/CameraSettings.swift',
     r'    var outputSize: Size2 \{\n.*?\n    \}\n    var previewReserve:',
     '''    var effectiveOutputResolution: Resolution {
        if actionStabilization && !resolution.isRAWFrameSize && resolution.longEdge > Resolution.action2_8K.longEdge {
            return .action2_8K
        }
        return resolution
    }
    var outputSize: Size2 {
        let outputResolution = effectiveOutputResolution
        if let exact=outputResolution.exactSize { return exact }
        return framing.size(longEdge:mode == .slowMotion ? min(1920,outputResolution.longEdge) : outputResolution.longEdge)
    }
    var previewReserve:''', re.S)

sub1('App/CameraSettings.swift',
     r'        if actionStabilization \{\n            if mode != \.video \{\n                actionStabilization=false\n            \} else \{\n                zoomLock=false\n                fps=min\(fps,60\)\n                if resolution == \.ultraHD \|\| resolution\.isRAWFrameSize \{ resolution = \.action2_8K \}\n                photographicStyle = \.standard\n                filter = \.original\n            \}\n        \}',
     '''        if actionStabilization && (mode != .video || fps > 60 || usesNativeMoviePipeline) {
            // Keep incompatible choices unchanged. The Action control becomes unavailable
            // instead of silently rewriting FPS, codec, color, style or framing locks.
            actionStabilization = false
        }''')

# Portrait already uses a rendered still path, so Horizon and Zoom Lock can remain real.
sub1('App/CameraSettings.swift',
     r'(        if mode == \.portrait \{.*?            portraitEffectsMatte = true\n)            horizonLock = false\n            zoomLock = false\n',
     r'\1', re.S)

rep('App/CameraSettings.swift', '    let isVirtual: Bool\n    let factor: Double\n',
    '    let isVirtual: Bool\n    let factor: Double\n    let focalLengthMM: Int\n')

# --- Native stabilization is independent from Action/Smart -----------------------------
rep('App/AdvancedCameraSupport.swift',
    '        if format.isVideoStabilizationModeSupported(.auto) { stabilizationModes.append(.auto) }\n', '')
sub1('App/AdvancedCameraSupport.swift',
     r'    static func preferredStabilization\(_ settings: CameraSettings, format: AVCaptureDevice\.Format\) -> AVCaptureVideoStabilizationMode \{\n        if settings\.actionStabilization \{\n            return settings\.actionNativeAssist \? preferredActionNativeStabilization\(for:format\) : \.off\n        \}\n        if settings\.horizonLock \|\| settings\.zoomLock \{ return \.off \}\n        let requested = settings\.stabilization\.avMode\n        return format\.isVideoStabilizationModeSupported\(requested\) \? requested : \.off\n    \}',
     '''    static func preferredStabilization(_ settings: CameraSettings, format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode {
        if settings.horizonLock || settings.zoomLock { return .off }
        let requested = settings.stabilization.avMode
        return format.isVideoStabilizationModeSupported(requested) ? requested : .off
    }''')

# --- Existing-install defaults + permission pass ---------------------------------------
rep('App/CameraModel.swift',
    '        if let data=try? Data(contentsOf:settingsURL), let saved=Self.decodeSettingsMigrating(data) {\n            settings=Self.preparedForLaunch(saved)\n        }\n        engine?.onState = { [weak self] state in\n',
    '        if let data=try? Data(contentsOf:settingsURL), let saved=Self.decodeSettingsMigrating(data) {\n            settings=Self.preparedForLaunch(saved)\n        }\n        let uxDefaultsKey = "HorizonCamera.UXDefaults.v2"\n        if !UserDefaults.standard.bool(forKey:uxDefaultsKey) {\n            settings.showOverview = true\n            settings.showStats = false\n            settings.includeLocationMetadata = true\n            if settings.stabilization == .auto { settings.stabilization = .standard }\n            UserDefaults.standard.set(true,forKey:uxDefaultsKey)\n        }\n        engine?.onState = { [weak self] state in\n')
rep('App/CameraModel.swift',
    '            if PHPhotoLibrary.authorizationStatus(for:.addOnly) == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for:.addOnly) }\n',
    '            if PHPhotoLibrary.authorizationStatus(for:.readWrite) == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for:.readWrite) }\n')

# Avoid the heavyweight live AVFoundation re-apply when only custom post/output controls changed.
anchor = '    func change(_ edit: (inout CameraSettings) -> Void) {'
p = Path('App/CameraModel.swift')
s = p.read_text()
if s.count(anchor) != 1:
    raise SystemExit('CameraModel.change anchor drifted')
helper = '''    private func needsAdvancedLiveApply(_ old: CameraSettings, _ next: CameraSettings) -> Bool {
        old.centerStage != next.centerStage || old.smartFraming != next.smartFraming ||
        old.lensCleaningHints != next.lensCleaningHints || old.lockCameraSwitching != next.lockCameraSwitching ||
        old.autoFPS != next.autoFPS || old.smoothAutofocus != next.smoothAutofocus ||
        old.faceDrivenAutofocus != next.faceDrivenAutofocus || old.focusRange != next.focusRange ||
        old.responsiveCapture != next.responsiveCapture || old.zeroShutterLag != next.zeroShutterLag ||
        old.fastCapturePrioritization != next.fastCapturePrioritization || old.autoDeferredPhotoDelivery != next.autoDeferredPhotoDelivery ||
        old.depthData != next.depthData || old.portraitEffectsMatte != next.portraitEffectsMatte || old.semanticMattes != next.semanticMattes ||
        old.constantColor != next.constantColor || old.sensorOrientationCompensation != next.sensorOrientationCompensation ||
        old.contentAwareDistortionCorrection != next.contentAwareDistortionCorrection || old.colorProfile != next.colorProfile ||
        old.audioMode != next.audioMode || old.windNoiseRemoval != next.windNoiseRemoval
    }

'''
p.write_text(s.replace(anchor, helper + anchor, 1))
rep('App/CameraModel.swift',
    '            if let engine { NativeMovieController.applyLiveSettings(next,engine:engine) }\n',
    '            if needsAdvancedLiveApply(old,next), let engine { NativeMovieController.applyLiveSettings(next,engine:engine) }\n')

rep('App/CameraModel.swift',
    '        case .proResLT, .proRes422, .proResHQ: return settings.mode == .video && capabilities.proRes\n',
    '        case .proResLT, .proRes422, .proResHQ: return settings.mode == .video && !settings.actionStabilization && capabilities.proRes\n')
rep('App/CameraModel.swift',
    '        guard settings.mode == .video, !settings.codec.isProResRAW else { return profile == .sdr && !settings.codec.isProResRAW }\n',
    '        guard settings.mode == .video, !settings.codec.isProResRAW, !settings.actionStabilization else { return profile == .sdr && !settings.codec.isProResRAW }\n')
rep('App/CameraModel.swift', '    var displayZoom: Double { currentLensFactor * settings.zoom }\n',
    '    var currentFocalLengthMM: Int { capabilities.lenses.first(where:{$0.id == capabilities.selectedLens})?.focalLengthMM ?? 24 }\n'
    '    var displayFocalLengthMM: Int { max(1,Int((Double(currentFocalLengthMM) * settings.zoom).rounded())) }\n'
    '    var isFrontCamera: Bool { capabilities.lenses.first(where:{$0.id == capabilities.selectedLens})?.isFront ?? false }\n'
    '    var displayZoom: Double { currentLensFactor * settings.zoom }\n')

# --- Action/Smart latency path ----------------------------------------------------------
rep('App/CaptureEngine.swift',
    '                        if old.actionStabilization != settings.actionStabilization || old.manualFocus != settings.manualFocus {\n',
    '                        if old.manualFocus != settings.manualFocus {\n')
sub1('App/CaptureEngine.swift',
     r'            let front=camera\.position == \.front\n            let factor=front \? 1\.0 : tan\(Double\(wideFOV\) \* \.pi / 360\) / tan\(Double\(camera\.activeFormat\.videoFieldOfView\) \* \.pi / 360\)\n            let label=front \? "Front" : \(abs\(factor-factor\.rounded\(\)\) < 0\.12 \? String\(format:"%\.0f×",factor\) : String\(format:"%\.1f×",factor\)\)\n            return LensOption\(id:camera\.uniqueID,label:label,name:camera\.localizedName,isFront:front,isVirtual:false,factor:max\(0\.5,factor\)\)',
     '''            let front=camera.position == .front
            let factor=front ? 1.0 : tan(Double(wideFOV) * .pi / 360) / tan(Double(camera.activeFormat.videoFieldOfView) * .pi / 360)
            let label=front ? "Front" : (abs(factor-factor.rounded()) < 0.12 ? String(format:"%.0f×",factor) : String(format:"%.1f×",factor))
            let focalLengthMM = front ? 24 : max(1,Int((24.0 * factor).rounded()))
            return LensOption(id:camera.uniqueID,label:label,name:camera.localizedName,isFront:front,isVirtual:false,factor:max(0.5,factor),focalLengthMM:focalLengthMM)''')

rep('App/ImagePipeline.swift', '    private var frozenAngle: Double?\n',
    '    private var frozenAngle: Double?\n    private var recording = false\n')
rep('App/ImagePipeline.swift',
    '    func beginRecording() { frozenAngle = lastPlan?.angle }\n    func endRecording() { frozenAngle = nil }\n',
    '    func beginRecording() { recording = true; frozenAngle = lastPlan?.angle }\n    func endRecording() { recording = false; frozenAngle = nil }\n')
rep('App/ImagePipeline.swift',
    '        let smartSteady = settings.smartArtifactGuard && settings.mode.isMovie\n',
    '        let smartSteady = recording && settings.smartArtifactGuard && settings.mode.isMovie\n')
rep('App/ImagePipeline.swift',
    '        if (settings.actionStabilization || smartSteady), let reading {\n',
    '        if recording && (settings.actionStabilization || smartSteady), let reading {\n')
sub1('App/ImagePipeline.swift',
     r'        let captureCenter = Point2\(previewPlan\.center\.x \+ actionOffset\.x\*size\.width,\n                                   previewPlan\.center\.y \+ actionOffset\.y\*size\.height\)\n        let capturePlan = try CropGeometry\.plan\(source:size, output:settings\.outputSize, angle:captureAngle,\n            zoom:renderedZoom, fullTurn:settings\.horizonLock, reserve:settings\.captureReserve,\n            requestedCenter:captureCenter\)',
     '''        let capturePlan: CropPlan
        if recording {
            let captureCenter = Point2(previewPlan.center.x + actionOffset.x*size.width,
                                       previewPlan.center.y + actionOffset.y*size.height)
            capturePlan = try CropGeometry.plan(source:size, output:settings.outputSize, angle:captureAngle,
                zoom:renderedZoom, fullTurn:settings.horizonLock, reserve:settings.captureReserve,
                requestedCenter:captureCenter)
        } else {
            capturePlan = previewPlan
        }''')
rep('App/ImagePipeline.swift',
    '        let recordingImage = renderer.applyLook(renderer.transform(source,plan:capturePlan),settings:settings)\n',
    '        let recordingImage = recording ? renderer.applyLook(renderer.transform(source,plan:capturePlan),settings:settings) : previewImage\n')

# --- Permission strings ----------------------------------------------------------------
rep('App/Info.plist',
    '\t<string>Optionally add your current location to photo and video metadata when you enable Location metadata.</string>\n',
    '\t<string>Add your current location to photo and video metadata. You can turn Location metadata off in camera settings.</string>\n')
rep('App/Info.plist',
    '\t<key>NSPhotoLibraryAddUsageDescription</key>\n\t<string>Save captured photos and videos to Apple Photos. No existing photos are read.</string>\n',
    '\t<key>NSPhotoLibraryAddUsageDescription</key>\n\t<string>Save captured photos and videos to Apple Photos.</string>\n'
    '\t<key>NSPhotoLibraryUsageDescription</key>\n\t<string>Show your camera library alongside captures made in Horizon.</string>\n')

# --- Regression tests ------------------------------------------------------------------
rep('Tests/HorizonCameraTests/AdvancedCameraTests.swift',
    '        XCTAssertFalse(s.grid); XCTAssertFalse(s.showOverview)\n'
    '        XCTAssertTrue(s.showDetectedText); XCTAssertTrue(s.smartArtifactGuard)\n'
    '        XCTAssertFalse(s.customMetadataEnabled); XCTAssertFalse(s.includeLocationMetadata)\n',
    '        XCTAssertFalse(s.grid); XCTAssertTrue(s.showOverview); XCTAssertFalse(s.showStats)\n'
    '        XCTAssertTrue(s.showDetectedText); XCTAssertTrue(s.smartArtifactGuard)\n'
    '        XCTAssertFalse(s.customMetadataEnabled); XCTAssertTrue(s.includeLocationMetadata)\n'
    '        XCTAssertEqual(s.stabilization,.standard)\n')
rep('Tests/HorizonCameraTests/AdvancedCameraTests.swift',
    '        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)\n'
    '        XCTAssertFalse(s.horizonLock); XCTAssertFalse(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)\n',
    '        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)\n'
    '        XCTAssertTrue(s.horizonLock); XCTAssertTrue(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)\n')

sub1('Tests/HorizonCameraTests/AdvancedCameraTests.swift',
     r'    func testActionMatchesPublicAppleEnvelopeAndDoesNotForceSDR\(\) \{.*?\n    \}',
     '''    func testActionDoesNotSilentlyRewriteIncompatibleSelections() {
        var s=CameraSettings(); let old=s
        s.mode = .video; s.resolution = .ultraHD; s.fps=120; s.actionStabilization=true; s.codec = .efficient; s.colorProfile = .hdrHLG
        s.normalize(changedFrom:old)
        XCTAssertEqual(s.fps,120,accuracy:0.001); XCTAssertEqual(s.resolution,.ultraHD)
        XCTAssertEqual(s.colorProfile,.hdrHLG); XCTAssertFalse(s.actionStabilization)

        var compatible=CameraSettings(); compatible.horizonLock=false; let before=compatible
        compatible.resolution = .ultraHD; compatible.actionStabilization=true
        compatible.normalize(changedFrom:before)
        XCTAssertTrue(compatible.actionStabilization); XCTAssertEqual(compatible.resolution,.ultraHD)
        XCTAssertEqual(compatible.effectiveOutputResolution,.action2_8K)
    }''', re.S)

sub1('Tests/HorizonCameraTests/AdvancedCameraTests.swift',
     r'        var action=CameraSettings\(\); let a0=action\n        action\.mode = \.video; action\.actionStabilization = true; action\.actionNativeAssist = true; action\.actionStrength = 0\.9\n        action\.zoomLock=true; action\.colorProfile = \.hdrHLG; action\.codec = \.proRes422; action\.audioMode = \.stereo\n        action\.normalize\(changedFrom:a0\)\n        XCTAssertTrue\(action\.actionStabilization\); XCTAssertTrue\(action\.actionNativeAssist\); XCTAssertFalse\(action\.zoomLock\)\n        XCTAssertEqual\(action\.codec,\.proRes422\); XCTAssertEqual\(action\.colorProfile,\.hdrHLG\); XCTAssertEqual\(action\.audioMode,\.stereo\)\n        XCTAssertFalse\(action\.horizonLock\); XCTAssertEqual\(action\.actionStrength,0\.82,accuracy:0\.001\); XCTAssertLessThan\(action\.captureReserve,0\.70\)',
     '''        var action=CameraSettings(); action.horizonLock=false; let a0=action
        action.mode = .video; action.actionStabilization = true; action.actionNativeAssist = true; action.actionStrength = 0.9; action.zoomLock=true
        action.normalize(changedFrom:a0)
        XCTAssertTrue(action.actionStabilization); XCTAssertTrue(action.actionNativeAssist); XCTAssertTrue(action.zoomLock)
        XCTAssertEqual(action.actionStrength,0.82,accuracy:0.001); XCTAssertLessThan(action.captureReserve,0.70)

        var incompatible=CameraSettings(); incompatible.horizonLock=false; let i0=incompatible
        incompatible.actionStabilization=true; incompatible.colorProfile = .hdrHLG; incompatible.codec = .proRes422; incompatible.audioMode = .stereo
        incompatible.normalize(changedFrom:i0)
        XCTAssertFalse(incompatible.actionStabilization)
        XCTAssertEqual(incompatible.codec,.proRes422); XCTAssertEqual(incompatible.colorProfile,.hdrHLG); XCTAssertEqual(incompatible.audioMode,.stereo)''')

# Sanity assertions before the workflow is allowed to commit anything.
s = Path('App/CameraSettings.swift').read_text()
assert 'var showOverview = true' in s
assert 'var showStats = false' in s
assert 'var includeLocationMetadata = true' in s
assert 'var stabilization: StabilizationChoice = .standard' in s
assert 'NSPhotoLibraryUsageDescription' in Path('App/Info.plist').read_text()
assert 'let recordingImage = recording ?' in Path('App/ImagePipeline.swift').read_text()
print('camera UX core patch prepared')
