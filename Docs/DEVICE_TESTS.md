# Physical-device validation checklist

**Status: not executed on a physical iPhone by the automated build.** None of these boxes should be marked passed merely because the app compiled, unit tests passed, or an IPA exists.

Record device model, iOS version, app commit/build, physical lens, output framing/resolution/FPS, source description, lock states and lighting for each result. Export the in-app diagnostic JSON alongside sample files. Do not include private images in public issues.

## Permissions, start and persistence

- [ ] Fresh install: camera/motion permission explanations appear and the app starts without an account or network.
- [ ] Camera denied: useful recovery message, no crash or fake live view.
- [ ] Microphone denied: normal Video is visibly silent; permission can later be enabled.
- [ ] Photos denied: photo/video remain in the local gallery and can be shared through Files.
- [ ] Relaunch: settings and captures persist; local deletion never touches Apple Photos.
- [ ] No camera hardware/simulator: app fails gracefully rather than claiming capture works.

## Horizon Lock

- [ ] Static rear-camera wall/grid: saved horizontal/vertical edges are level and match preview orientation.
- [ ] Roll 0 → 90 → 180 → 270 → 360 degrees, then reverse. Test both 9:16 and 16:9 files.
- [ ] Multiple complete turns: no wrap discontinuity, sudden 180-degree flip, black corner or angle-dependent zoom pumping.
- [ ] Repeat using front camera with selfie mirroring on and off; confirm roll direction and saved orientation.
- [ ] Repeat with each physical rear lens; document source FOV and output crop detail.
- [ ] Point nearly straight up/down: gyro-hold status appears; no claim of a reliable gravity horizon at the singularity.
- [ ] Test fast rolls and slow rolls in bright light. Measure steady offset separately from timing lag. Keep trim/offset at zero until measured.
- [ ] Low light: quantify blur instead of interpreting a level horizon as restored image detail.

## Zoom Lock and combined use

- [ ] Select a distinctive static subject at an off-center screen point. Shake the phone gently; verify the crop moves and the subject stays at the selected point.
- [ ] Repeat at 2x, 5x and higher digital zoom. Compare saved output, not only the reticle.
- [ ] Verify wide-view inset depicts the moving crop and surrounding source image.
- [ ] Move the target beyond the available crop: Edge warning appears; no fabricated pixels or false lock.
- [ ] Cover the subject or leave frame: Lost appears; tracker does not silently acquire a different object. Tap to reacquire.
- [ ] Enable both locks: roll the phone while following the tapped subject; framing and saved output agree.
- [ ] With Zoom Lock off, pinch around an off-center point: zoom remains anchored near the fingers rather than recentering by default.
- [ ] Native lens switch, mirror/framing change and reset clear old tracking geometry.

## Video, sound and modes

- [ ] 1080p/30, 1080p/60 and supported 4K combinations produce decodable, seekable files with advertised output dimensions.
- [ ] Unsupported lens/FPS/4K combinations are rejected with a useful message, not silently mislabeled.
- [ ] Clap/audio sync at start and near the end of a longer normal recording. Inspect actual presentation timestamps if offset/drift appears.
- [ ] Start/stop immediately: no empty corrupt movie is presented as a successful capture.
- [ ] Slo-mo records supported 120-fps input and plays approximately four times slower at 30 fps, without audio.
- [ ] Time-lapse samples the selected real interval and plays consecutive frames at 30 fps, without audio.
- [ ] With Horizon Lock off, landscape orientation does not flip mid-recording.
- [ ] Monitor dropped-frame diagnostics and heat during sustained recording, especially both locks at 4K/60.
- [ ] Upscaled warning reflects source crop detail; no assertion that cropping recovers optical resolution.

## Photos and common controls

- [ ] Photo flash off/auto/on; video torch; timer 3/10 seconds and cancellation.
- [ ] Tap focus/exposure, long-press AE/AF lock, manual focus, ISO/shutter clamping, EV and white-balance lock.
- [ ] Processed still matches lock/crop/filter orientation at the exposure time. Compare near and distant subjects to expose photo/video FOV differences.
- [ ] Native unprocessed still retains full dimensions; test front-camera mirroring separately.
- [ ] Supported native Live Photo captures actual paired resources and plays in the local viewer and Photos.
- [ ] Supported RAW+processed capture provides a valid DNG, not a renamed JPEG.
- [ ] Processing combinations do not falsely advertise a stabilized RAW or stabilized Live Photo.

## Interrupted recording and data safety

- [ ] Home/lock/background transition finalizes playable media without continuing background capture.
- [ ] Incoming call/audio interruption/camera interruption: file is finalized or a clear failure is reported.
- [ ] Camera-service reset can recover without stale target, false recording state or runaway memory.
- [ ] Low disk space prevents a new capture and safely stops an existing one.
- [ ] Critical thermal state stops capture and reports why.
- [ ] Interrupted Photos export still leaves the local copy available.
- [ ] Gallery video playback returns cleanly to camera capture/audio mode.

## Acceptance

Do not claim Samsung/Apple image-quality parity until matched real-world reference recordings establish it. Automated mathematical bounds test crop geometry under their coordinate assumptions; they do not measure physical sensor calibration, rolling shutter, blur, tracker identity or OS camera behavior.
