from pathlib import Path

p=Path('Tests/HorizonCameraTests/PipelineTests.swift')
s=p.read_text()
needle='        processor.configure(settings,front:false,horizontalFOVDegrees:70)\n        let input=try buffer(pattern(width:1280,height:720),renderer:renderer)\n'
replacement='        processor.configure(settings,front:false,horizontalFOVDegrees:70)\n        processor.beginRecording(); defer { processor.endRecording() }\n        let input=try buffer(pattern(width:1280,height:720),renderer:renderer)\n'
# Exactly the three recording-plan tests share this setup; Zoom Lock and normal-zoom tests
# later in the file also share similar text, so target the three named function ranges.
for name in [
    'testSmartSteadyChangesRecordingPlanWithoutWarpingPreview',
    'testActionAndArtifactGuardAffectRecordingPlanNotLivePreviewPlan',
    'testSmartArtifactGuardUsesSaferOutputCropWithLiveHorizonPreview'
]:
    start=s.index('    func '+name)
    next_func=s.find('\n    func ',start+8)
    end=len(s) if next_func < 0 else next_func
    block=s[start:end]
    if block.count(needle) != 1:
        raise SystemExit(f'{name}: expected one setup match, found {block.count(needle)}')
    block=block.replace(needle,replacement,1)
    s=s[:start]+block+s[end:]
p.write_text(s)
print('updated recording-only stabilization tests')
