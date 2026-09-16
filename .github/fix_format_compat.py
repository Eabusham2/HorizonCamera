from pathlib import Path
import re


def rep(path, old, new):
    p=Path(path); s=p.read_text()
    if s.count(old) != 1:
        raise SystemExit(f'{path}: expected one match for {old!r}, got {s.count(old)}')
    p.write_text(s.replace(old,new,1))

# Portrait is already a rendered photo pipeline; keep the user's chosen aspect instead
# of silently forcing 3:4 every time another setting changes.
rep('App/CameraSettings.swift',
    '            livePhoto = false\n            photoFraming = .classic\n        }\n',
    '            livePhoto = false\n        }\n')

# Frame-size and frame-rate menus are a pair: selecting one must not silently mutate
# the other. Gray a size that cannot run the currently selected capture rate.
p=Path('App/CameraModel.swift'); s=p.read_text()
old='''    func resolutionAvailable(_ resolution: Resolution) -> Bool {
        if settings.codec.isProResRAW {
            guard resolution.isRAWFrameSize else { return false }
            return capabilities.supportedResolutions.contains(resolution)
        }
        if resolution.isRAWFrameSize { return false }
        if resolution == .action2_8K { return settings.actionStabilization && capabilities.supportedResolutions.contains(resolution) }
        if settings.actionStabilization && resolution == .ultraHD { return false }
        return capabilities.supportedResolutions.contains(resolution)
    }
'''
new='''    func resolutionAvailable(_ resolution: Resolution) -> Bool {
        if settings.codec.isProResRAW {
            guard resolution.isRAWFrameSize, capabilities.supportedResolutions.contains(resolution) else { return false }
        } else {
            if resolution.isRAWFrameSize { return false }
            if resolution == .action2_8K && !settings.actionStabilization { return false }
            guard capabilities.supportedResolutions.contains(resolution) else { return false }
        }
        if let rates=capabilities.supportedFPSByResolution[resolution], !rates.isEmpty,
           !rates.contains(where:{abs($0-settings.captureFPS)<0.02}) { return false }
        return true
    }
'''
if s.count(old) != 1: raise SystemExit('CameraModel resolutionAvailable block drifted')
p.write_text(s.replace(old,new,1))

# Make the UI reason specific when the camera supports the size but not at current FPS.
p=Path('App/CameraView.swift'); s=p.read_text()
old='''    private func resolutionUnavailableReason(_ resolution:Resolution) -> String? {
        if model.resolutionAvailable(resolution) { return nil }
        if model.settings.codec.isProResRAW { return resolution.isRAWFrameSize ? "not supported by this camera" : "RAW uses sensor frame sizes" }
        if resolution.isRAWFrameSize { return "requires ProRes RAW" }
        return model.isFrontCamera ? "not supported by the front camera" : "not supported by the active rear camera/format"
    }
'''
new='''    private func resolutionUnavailableReason(_ resolution:Resolution) -> String? {
        if model.resolutionAvailable(resolution) { return nil }
        if model.settings.codec.isProResRAW { return resolution.isRAWFrameSize ? "not supported by this camera at the selected fps" : "RAW uses sensor frame sizes" }
        if resolution.isRAWFrameSize { return "requires ProRes RAW" }
        if resolution == .action2_8K && !model.settings.actionStabilization { return "available when Action is on" }
        if model.capabilities.supportedResolutions.contains(resolution),
           let rates=model.capabilities.supportedFPSByResolution[resolution], !rates.isEmpty {
            return "not available at \\(FrameRateCatalog.label(model.settings.captureFPS)) fps"
        }
        return model.isFrontCamera ? "not supported by the front camera" : "not supported by the active rear camera/format"
    }
'''
if s.count(old) != 1: raise SystemExit('CameraView resolution reason block drifted')
p.write_text(s.replace(old,new,1))

# Regression: a non-classic Portrait crop must survive normalization.
p=Path('Tests/HorizonCameraTests/AdvancedCameraTests.swift'); s=p.read_text()
old='''        s.mode = .portrait; s.horizonLock = true; s.zoomLock = true; s.raw = true; s.livePhoto = true; s.filter = .vivid
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.mode.isPhotoMode); XCTAssertFalse(s.mode.isMovie)
        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)
        XCTAssertTrue(s.horizonLock); XCTAssertTrue(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)
        XCTAssertEqual(s.filter,.original); XCTAssertEqual(s.photoFraming,.classic)
'''
new='''        s.mode = .portrait; s.horizonLock = true; s.zoomLock = true; s.raw = true; s.livePhoto = true; s.filter = .vivid; s.photoFraming = .square
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.mode.isPhotoMode); XCTAssertFalse(s.mode.isMovie)
        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)
        XCTAssertTrue(s.horizonLock); XCTAssertTrue(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)
        XCTAssertEqual(s.filter,.original); XCTAssertEqual(s.photoFraming,.square)
'''
if s.count(old) != 1: raise SystemExit('Portrait normalization test drifted')
p.write_text(s.replace(old,new,1))

print('format compatibility patch prepared')
