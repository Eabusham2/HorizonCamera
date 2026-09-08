#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
python3 Scripts/generate_project.py
xcrun simctl list devices available --json > build/simulator-devices.json
UDID="$(python3 - <<'PY'
import json
from pathlib import Path
devices=json.loads(Path('build/simulator-devices.json').read_text())['devices']
for runtime in sorted(devices,reverse=True):
    if '.iOS-' not in runtime:continue
    phones=[d for d in devices[runtime] if d.get('isAvailable') and d.get('name','').startswith('iPhone')]
    if phones:
        print(phones[0]['udid']);break
else:raise SystemExit('No installed, available iPhone simulator')
PY
)"
rm -rf build/PipelineTests.xcresult
xcodebuild -project HorizonCamera.xcodeproj -scheme HorizonCamera -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -destination-timeout 120 \
  -derivedDataPath build/Simulator -resultBundlePath build/PipelineTests.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test 2>&1 | tee build/logs/pipeline-tests.log
