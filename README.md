# HorizonCamera

A native **Swift / SwiftUI iPhone camera app** with independent **Horizon Lock** and **Zoom Lock** checkboxes. No website wrapper, JavaScript camera, cloud processing, account, analytics or external Swift dependency.

**Build status:** [GitHub Actions](https://github.com/Eabusham2/HorizonCamera/actions). Only a successful gated build publishes an IPA. The automated geometry/motion/timeline tests have run successfully; physical-device image quality is not certified by compilation or unit tests. See [device validation](Docs/DEVICE_TESTS.md).

## Get the app

Open [Releases](https://github.com/Eabusham2/HorizonCamera/releases) and download **HorizonCamera-unsigned.ipa** from a successful build. Its SHA-256 file and `build-info.json` identify the bytes and source commit.

**An unsigned IPA cannot install unchanged on a normal iPhone.** Re-sign it using your own signing certificate/profile or sideloading tool. The build requires no Apple developer secrets and does not bypass iOS signing. The repository and its release assets are public; the IPA still requires your own iOS signing before installation.

## The two locks

**Horizon Lock** uses timestamp-aligned Core Motion measurements to counter-rotate both the viewfinder and saved frames through full turns. A fixed, full-turn-safe crop avoids black corners and rotation-dependent zoom pumping. It costs field of view and sometimes effective resolution. Looking directly up or down makes the gravity-defined horizon ambiguous; the UI reports gyro hold. Native electronic stabilization is disabled when either custom lock is on so an unknown native crop cannot conflict with the custom transform.

**Zoom Lock** follows the subject you tap using Vision. It moves the crop away from the image center to keep that subject at the selected screen position, rather than simply locking magnification. A wide-view inset shows the available sensor image and crop. Low-confidence tracking visibly becomes **Lost**; it does not silently acquire a different subject. Crop exhaustion is reported as **Edge**. Both locks can work together.

Pinching without Zoom Lock zooms around the pinch location, not always the image center. Both locks affect the **saved photo/video**, not merely a viewfinder overlay. This is an independent implementation, not Samsung's proprietary algorithm or a guarantee of identical image quality. Blur, rolling shutter, parallax, missing sensor area, occlusion and timestamp accuracy can limit results.

## Camera features

| Area | Implemented |
|---|---|
| Modes | Photo, Video, real 120-to-30 fps Slo-mo on supported lenses, frame-sampled Time-lapse |
| Video | 1080p / 4K output, 30 / 60 fps where supported, HEVC or H.264 SDR; mono AAC microphone audio in normal Video |
| Stills | Native full-resolution capture when unprocessed; timestamp-aligned locked/cropped/filtered still processing |
| Native extras | Live Photo capture/playback and RAW + processed photos when processing is off and the device supports them |
| Lenses | Device-discovered front, ultrawide, main and telephoto physical cameras; no invented lens buttons |
| Controls | Pinch-to-point digital zoom, zoom slider, tap focus/exposure, AE/AF lock, exposure compensation, manual focus/ISO/shutter, white-balance lock, flash, torch |
| Framing | 9:16, 16:9, 1:1, 3:4; portrait control layout while the phone rolls |
| Viewfinder | Grid, level, filters, subject reticle, tracking/edge/lost state, sensor-view inset, upscaling warning |
| Capture / storage | 3/10-second photo timer, gallery, photo/video/Live Photo playback, sharing, RAW sharing, optional add-only Photos export |
| Resilience | Serialized session/frame processing, bounded preview retention, backpressure counters, timestamped audio, interruption/background finalization, thermal/disk checks, recoverable local files |

**Not implemented in this build:** Apple's full Night mode fusion pipeline, Portrait depth effects, Cinematic depth recording, Panorama, Apple Photographic Styles, ProRes, Dolby Vision, spatial video, Camera Control hardware integration, lock-screen camera extension or complete stock Camera parity. Some have public APIs; this list means *not implemented*, not *impossible*. There are no fake buttons for those modes.

Live Photos and RAW are native-only and mutually exclusive: enabling one disables the other. Modifying the still while retaining an unmodified paired movie or RAW would not be an honest stabilized capture. Turn both locks off, set digital zoom to 1x, use Original filter and 3:4 photo framing for native extras.

4K denotes the encoded canvas, **not recovered 4K detail**. The app reports available source-crop pixels and warns about upscaling. Stabilization and high digital zoom reduce effective detail. Slo-mo and time-lapse omit audio. Physical-device verification is still needed for exact still/preview field-of-view correspondence, roll calibration and sustained performance.

## Use

1. Grant Camera and Motion access, and Microphone for audio. Photos permission is requested only when saving a capture there.
2. Choose mode, lens, output framing, resolution and frame rate. Enable the desired lock checkboxes **before** recording.
3. With Zoom Lock on, tap a distinctive subject. Watch **Locked**, **Lost** or **Edge**, not merely the enabled checkbox. Tap again to reacquire after loss.
4. Record or take a photo. Configuration changes are disabled during recording; digital zoom and subject selection remain available. Choose 16:9 for a landscape file or 9:16 for portrait. The control layout stays in portrait during rolls.
5. Open the bottom-left gallery to play, share or save. Captures are also available through Files. Denied Photos access does not delete them.

Hold the viewfinder to toggle AE/AF lock. Tap to focus and select a tracking target. At the crop edge, aim the phone back toward the subject; no software can recover a subject outside the sensor.

## Build

Requires a Mac with Xcode 26 or newer and an iPhone running iOS 17+. The generated Xcode project is committed. Open `HorizonCamera.xcodeproj`, select your signing team for a directly signed device build, and run.

```sh
# Portable regression suite (Swift 5.9+; supports Linux as well as macOS)
swift test

# Regenerate after adding/removing Swift source files
python3 Scripts/generate_project.py

# Compile, remove signing data, package and verify the ARM64 IPA
bash Scripts/build_unsigned.sh
```

`Scripts/generate_icon.py` recreates the original icon with Python's standard library. The icon is already committed. No CocoaPods, XcodeGen or external package bootstrap is needed.

### GitHub Actions

Pushes to `main`, version tags (`v*`) and manual dispatch run the workflow. Documentation-only pushes are ignored. The runner's supported Xcode is used with its matching installed simulator runtimes; the exact toolchain is recorded in `build-info.json`.

The pipeline runs core regression tests, compiles the simulator app, builds the physical-device app with signing disabled, verifies an unsigned ARM64 Mach-O inside `Payload/HorizonCamera.app`, uploads artifacts, and publishes a prerelease. Version-tag builds publish a normal release. A failed test, compile or IPA-verification gate cannot publish an IPA. Pull requests do not publish releases.

## Source layout

`Core/` contains crop geometry, inverse touch mapping, horizon math, motion interpolation and recording timelines. `App/` contains AVFoundation capture, Vision tracking, Core Image/Metal rendering, SwiftUI controls and local/Photos storage. `Tests/HorizonCoreTests/` covers full-turn crop safety, angle continuity, front/rear sign, timestamps, off-center anchors, A/V alignment and time remapping.

See [architecture](Docs/ARCHITECTURE.md) and [physical-device checklist](Docs/DEVICE_TESTS.md).

## Technical references

- [Samsung Horizontal Lock](https://www.samsung.com/us/support/answer/ANS10010423/)
- [Samsung Zoom Lock](https://www.samsung.com/africa_en/support/mobile-devices/enhanced-zoom-and-nightography-on-galaxy-devices/)
- [Apple AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)
- [Core Motion device motion](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data)
- [Vision object tracking](https://developer.apple.com/documentation/vision/vntrackobjectrequest)
- [Capture-session synchronization clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)
