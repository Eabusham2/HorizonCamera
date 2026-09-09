# HorizonCamera

[![iOS build](https://github.com/Eabusham2/HorizonCamera/actions/workflows/ios-release.yml/badge.svg?branch=main)](https://github.com/Eabusham2/HorizonCamera/actions/workflows/ios-release.yml)

A public, native **Swift / SwiftUI iPhone camera** built on AVFoundation, Core Motion, Vision, Core Image and Metal. Its two signature controls are **360° Horizon Lock** and **subject-tracked off-center Zoom Lock**, and it also exposes a broad set of Apple's public camera capture APIs instead of hiding them behind hard-coded presets.

There is no website wrapper, cloud processing, analytics account, advertising SDK or external Swift package dependency.

## Download

Open **[Releases](https://github.com/Eabusham2/HorizonCamera/releases)** and download `HorizonCamera-unsigned.ipa` from the newest successful build. Every release also contains a SHA-256 file and `build-info.json` tying the IPA to its source commit/toolchain.

> **Unsigned IPA:** iOS will not install the file unchanged. Re-sign it with your own certificate/profile or sideloading tool. The GitHub build intentionally contains no Apple developer secrets and does not bypass code signing.

## Horizon Lock and Zoom Lock

### Horizon Lock

Horizon Lock uses timestamp-aligned Core Motion gravity/gyro data to counter-rotate the **preview and saved pixels** through full phone rolls. The full-turn mode uses a fixed safety crop so a 45°, 90°, 180° or 360° roll does not reveal black corners or cause rotation-dependent zoom pumping. Looking nearly straight up/down makes the gravity-defined horizon ambiguous; the app reports gyro hold rather than claiming a reliable level.

### Zoom Lock

Zoom Lock uses Vision tracking after you tap a subject. Instead of always centering the crop, it keeps the tracked subject at the **screen position you selected**, allowing an off-center composition to remain stable. The UI reports `Locked`, `Lost` and `Edge`; a lost subject is not silently replaced. A wide-view inset shows the crop's remaining travel.

Both custom locks can work together and affect saved custom-pipeline photos/videos. Native Cinematic, Spatial, ProRes/Log and multichannel movie modes deliberately use AVFoundation's native movie pipeline, so custom pixel-transform locks are disabled there instead of showing a fake “on” state.

## Apple Camera / AVFoundation parity

HorizonCamera does **not** claim to clone Apple's proprietary image-processing algorithms. The table separates features that can be implemented through public capture APIs from stock-Camera behavior that Apple does not expose as a drop-in API.

### Modes

| Apple Camera area | HorizonCamera status |
|---|---|
| Photo | ✅ Native maximum-quality still capture plus optional custom Horizon/Zoom/filter processing |
| Portrait | ✅ **Depth-capable Portrait mode**: requests depth and Portrait Effects matte data and embeds supported auxiliary data; does **not** claim Apple's proprietary Portrait Lighting/bokeh renderer |
| Video | ✅ Custom stabilized/video-processing path or native AVFoundation path when advanced native features require it |
| Time-lapse | ✅ Frame-sampled time-lapse with configurable interval |
| Slo-mo | ✅ 120 fps and 240 fps when the active iPhone/lens exposes them, retimed for 30 fps playback |
| Cinematic | ✅ Capability-gated public **iOS 26+ Cinematic capture** path, required Cinematic metadata track, and simulated aperture control |
| Spatial | ✅ Capability-gated **Spatial Video** capture through `AVCaptureMovieFileOutput` on supported devices/formats |
| Panorama | ❌ No first-party AVFoundation “make a stock Pano” API; HorizonCamera does not ship a fake panorama button |
| Spatial Photo | ⚠️ Stock Camera can create spatial photos on supported devices, but HorizonCamera currently exposes the public Spatial **Video** path only |

### Photo capture features

| Feature | Status |
|---|---|
| Live Photo | ✅ Native paired-photo/movie capture on compatible nonprocessed photo settings |
| JPEG / HEIF | ✅ Compatible / efficient output choices |
| Bayer RAW | ✅ When exposed by the camera |
| Apple ProRAW | ✅ Preferred independently from Bayer RAW when `isAppleProRAWSupported` reports support |
| Photo quality priority | ✅ Speed / Balanced / Quality |
| Responsive capture | ✅ Capability-gated |
| Zero shutter lag | ✅ Capability-gated |
| Prioritize faster shooting | ✅ Uses AVFoundation fast-capture prioritization when supported |
| Automatic deferred photo delivery | ✅ Capability-gated |
| Depth data | ✅ Capture + embedded depth in compatible HEIF/JPEG |
| Filtered depth | ✅ Toggleable |
| Portrait Effects matte | ✅ Capture + embed when depth/pipeline support it |
| Semantic segmentation mattes | ✅ Requests every semantic matte type currently reported by the configured output and embeds them in compatible files |
| Constant Color | ✅ iOS 18+ when supported, with optional fallback photo; incompatible RAW/Live combinations are prevented |
| Auto red-eye reduction | ✅ Capability-gated |
| Content-aware distortion correction | ✅ Capability-gated |
| Virtual-device fusion | ✅ Enabled when the configured output/device reports fusion support |
| Sensor-orientation compensation | ✅ iOS 26+ capability-gated, never falsely applied to RAW |
| Camera calibration data | ✅ Toggle exposed when the active output configuration actually reports calibration delivery support |
| Flash | ✅ Off / Auto / On |
| 3 s / 10 s timer | ✅ |
| 3:4 / 1:1 / 9:16 / 16:9 framing | ✅ Custom photo path; native Portrait is constrained to compatible framing |

AVFoundation requires long pipeline reconfiguration for depth and semantic mattes, so HorizonCamera configures those at the output/session level rather than setting a cosmetic per-shot flag.

### Video formats and capture

| Feature | Status |
|---|---|
| Resolution | ✅ 720p / 1080p / 4K when supported by the selected camera format |
| Frame rates | ✅ 24 / 25 / 30 / 50 / 60 / 120 fps choices when exposed; Slo-mo checks 120/240 across device formats |
| Auto FPS | ✅ iOS 18+ low-light automatic frame-rate control when supported |
| H.264 | ✅ |
| HEVC | ✅ |
| Apple ProRes 422 LT | ✅ Native movie path when available |
| Apple ProRes 422 | ✅ Native movie path when available |
| Apple ProRes 422 HQ | ✅ Native movie path when available |
| SDR / Rec.709 | ✅ Custom writer renders in Rec.709 and tags output consistently |
| HDR / HLG | ✅ Capability-gated native color-space/HDR path |
| Apple Log | ✅ Capability-gated; Log selection forces a compatible ProRes/native path |
| Apple Log 2 | ✅ iOS 26+ when the active format reports it |
| Native video stabilization | ✅ Off / Standard / Cinematic / Cinematic Extended plus iOS 18/26 modes when the format reports support |
| Orientation/mirroring metadata track | ✅ Native movie output records changes; portrait/landscape rotation is explicitly configured |
| Native movie digital zoom | ✅ Ramps the **physical capture device**, so saved Cinematic/Spatial/ProRes footage matches the native preview zoom instead of applying a preview-only crop |

**HDR / HLG is not described as Dolby Vision.** Apple's Camera app's exact Dolby Vision processing/look is not reproduced.

### Focus, exposure and white balance

- Tap focus + tap exposure.
- AE/AF lock.
- Manual focus position on devices that permit lens-position locking.
- Smooth autofocus toggle.
- Face-driven autofocus toggle, configured using Apple's required explicit face-AF state sequence.
- Autofocus range restriction: Full / Near / Far when supported.
- Exposure compensation.
- Manual ISO and shutter duration with camera/format bounds.
- White-balance lock.
- Low-light boost where the device supports it.
- An **Auto** virtual dual/dual-wide/triple camera option when iOS exposes one, plus physical front / ultrawide / wide / telephoto choices. Virtual cameras can use Apple's public seamless constituent switching/fusion behavior.

### Audio

- Microphone enable/disable.
- Mono AAC in the custom movie writer.
- Stereo capture through the native input when supported.
- Spatial / first-order ambisonic audio when supported by iOS/device input.
- Wind-noise removal when the input reports support.
- Slo-mo and time-lapse intentionally omit audio because their timelines are remapped.

## Capture metadata

HorizonCamera exposes editable fields for **Title, Author, Copyright, Description and comma-separated Keywords**.

**Native movies** embed QuickTime metadata for title, author, copyright, description, keywords, HorizonCamera software attribution and creation date. Native movie capture also retains AVFoundation orientation/mirroring metadata where supported.

**Native photos** receive standards-based TIFF/IPTC properties through `AVCapturePhotoSettings.metadata`. **Processed Horizon/Zoom/filter photos are re-encoded with ImageIO and the same metadata is explicitly reattached**, so using the custom stabilization path does not silently erase it. Camera-generated EXIF data remains managed by AVFoundation.

Location metadata is **off by default**. If you enable it, HorizonCamera requests When In Use location permission and embeds a recent fix using the standard ImageIO GPS dictionary for photos and ISO-6709 QuickTime metadata for movies. Diagnostics never include coordinates.

## Viewfinder and camera controls

- Grid and level indicator.
- Pinch-to-point zoom: without Zoom Lock, the point under your fingers remains anchored while the crop zooms.
- Smooth Zoom Lock transitions.
- Subject tracking reticle plus `Locked` / `Lost` / `Edge` states.
- Wide sensor-view inset.
- Effective source-crop detail and upscaling warnings.
- Front-camera mirroring control.
- Flash / torch controls.
- Physical lens selection and camera flip.
- Controls remain portrait-oriented while the camera image may roll for Horizon Lock.
- Settings persist between launches.

## What is intentionally *not* presented as Apple parity

These stock-Camera behaviors either use proprietary/system processing, require a separate specialized pipeline/extension, or do not have a direct public API equivalent. HorizonCamera keeps them visibly absent rather than putting in nonfunctional buttons:

- Apple's exact **Night mode / multi-frame fusion** and Night Portrait processing.
- **Photographic Styles** and Apple's current stock rendering/tone-mapping recipes.
- Stock **Scene Detection** look decisions.
- Apple's exact **Portrait Lighting**, automatic portrait relighting and stock depth-rendering look.
- Stock **Panorama** stitching UI/algorithm.
- Apple's exact **Action mode** stabilization algorithm. HorizonCamera exposes the stabilization modes the active AVFoundation format publicly reports instead.
- The stock Camera app's exact **Dolby Vision HDR** pipeline/look; HorizonCamera exposes public HLG HDR where available.
- Apple's exact stock **Macro Control** UI/trigger thresholds. The Auto virtual camera can perform public AVFoundation constituent switching based on zoom/light/focus conditions, and physical ultrawide selection remains available, but HorizonCamera does not claim Apple's private Camera-app macro heuristics.
- **Camera Control** hardware gestures/system overlay behavior.
- Apple's lock-screen Camera replacement / system Camera entitlement behavior.
- Stock Spatial **Photo** authoring; Spatial Video is implemented through public AVFoundation APIs.

This distinction is deliberate: “supported” in the UI means a real capture API/code path exists and the current device reports capability.

## Storage and privacy

Captures are written to `Documents/Captures` first and indexed in a local manifest. If the app is interrupted after a file is created but before the index updates, unindexed JPEG/HEIC/DNG/MOV files are recovered on next launch.

Saving to Apple Photos uses **add-only** authorization. Denied Photos access does not delete the local capture; Share/Files remain available. The app asks for Camera and Motion access, optional Microphone access, and optional When In Use Location access only if you turn on Location metadata. It has no account/login requirement and does not upload captures.

## Build and release gates

Requires Xcode 26+ for the complete current API surface. The deployment target remains iOS 17; iOS 18/26 APIs are guarded at runtime and their controls appear only when supported.

```sh
# portable crop / motion / timing regressions
swift test

# regenerate the deterministic Xcode project after source changes
python3 Scripts/generate_project.py

# execute actual iOS simulator rendering/Vision/movie tests
bash Scripts/test_simulator.sh

# compile ARM64 device app, remove signing material, package + verify unsigned IPA
bash Scripts/build_unsigned.sh
```

GitHub Actions blocks release publication unless all gates succeed:

1. deterministic project/plist generation + validation;
2. portable core regressions;
3. complete iOS simulator compile;
4. executed iOS tests for rendered pixels, full-turn crop safety, Vision tracking, off-center/smoothed zoom, encoded movie pixels, audio retiming, Rec.709, processed stills and metadata;
5. Release ARM64 iPhone compilation;
6. unsigned IPA structure/platform/privacy/Mach-O verification;
7. artifact upload and GitHub Release publication.

Pull requests run the checks without publishing a release. Successful `main` pushes publish prerelease unsigned IPAs; `v*` tags publish normal releases.

## Architecture

- `Core/` — crop geometry/inverse mapping, horizon estimator, motion interpolation, recording cadence/timeline math.
- `App/CaptureEngine.swift` — serialized AVCaptureSession, physical camera inputs, still output, custom video sample pipeline.
- `App/AdvancedCameraSupport.swift` — native Cinematic / Spatial / ProRes / advanced audio and AVFoundation capability mapping.
- `App/CaptureMetadata.swift` — TIFF/IPTC processed/native photo metadata handling.
- `App/ImagePipeline.swift` — one transform shared by preview, tracking, touch mapping and custom saved output.
- `App/MovieRecorder.swift` — custom processed MOV writer with timestamped video/audio.
- `Tests/` — portable geometry/motion tests plus executed iOS pipeline tests.

See [architecture notes](Docs/ARCHITECTURE.md) and the [physical-device validation checklist](Docs/DEVICE_TESTS.md).

## Official references

- [Apple: Camera basics and modes](https://support.apple.com/guide/iphone/camera-basics-iph263472f78/ios)
- [Apple: AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)
- [Apple: AVCapturePhotoSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings)
- [Apple: AVCaptureDevice focus](https://developer.apple.com/documentation/avfoundation/capture-device-focus)
- [Apple: AVCaptureDevice zoom](https://developer.apple.com/documentation/avfoundation/capture-device-zoom)
- [Apple: AVCaptureMovieFileOutput](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput)
- [Samsung: Camera / Super Steady documentation](https://www.samsung.com/us/support/answer/ANS00092462/)

## License / contribution note

This is an independent camera implementation. “Apple”, “iPhone”, “ProRAW”, “ProRes” and related names identify platform technologies/features; “Samsung” identifies the reference feature family discussed above. No proprietary Apple or Samsung camera source code is included.
