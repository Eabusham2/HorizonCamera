# HorizonCamera

[![iOS build](https://github.com/Eabusham2/HorizonCamera/actions/workflows/ios-release.yml/badge.svg?branch=main)](https://github.com/Eabusham2/HorizonCamera/actions/workflows/ios-release.yml)

A public, native **Swift / SwiftUI iPhone camera** built on AVFoundation, Core Motion, Vision, Core Image and Metal. Its two signature controls are **360° Horizon Lock** and an **edge-limited floating-frame Zoom Lock**, and it also exposes a broad set of Apple's public camera capture APIs instead of hiding them behind hard-coded presets.

There is no website wrapper, cloud processing, analytics account, advertising SDK or external Swift package dependency.

## Download

Open **[Releases](https://github.com/Eabusham2/HorizonCamera/releases)** and download `HorizonCamera-unsigned.ipa` from the newest successful build. Every release also contains a SHA-256 file and `build-info.json` tying the IPA to its source commit/toolchain.

> **Unsigned IPA:** iOS will not install the file unchanged. Re-sign it with your own certificate/profile or sideloading tool. The GitHub build intentionally contains no Apple developer secrets and does not bypass code signing.

## Horizon Lock and Zoom Lock

### Horizon Lock

Horizon Lock uses timestamp-aligned Core Motion gravity/gyro data to counter-rotate the **preview and saved pixels** through full phone rolls. The full-turn mode uses a fixed safety crop so a 45°, 90°, 180° or 360° roll does not reveal black corners or cause rotation-dependent zoom pumping. Looking nearly straight up/down makes the gravity-defined horizon ambiguous; the app reports gyro hold rather than claiming a reliable level.

### Zoom Lock

Zoom Lock locks the **zoomed framing itself**, not a recognized subject. Core Motion pans the crop in the opposite direction inside the wider sensor image so the selected view stays fixed while you move the phone. When the crop reaches a real sensor edge it pins there and the framing begins following the phone; reverse direction and the crop immediately regains travel until the opposite edge. A tap while Zoom Lock is active re-centers the locked window on that point. The optional mini overview is off by default. When enabled it shows the uncropped active physical lens and overlays the actual output crop in yellow; at 0.5× the active source is the ultra-wide lens, while the normal 1× path uses the main camera.

Horizon and Zoom Lock are WYSIWYG: their preview uses the same live crop/level geometry that drives compatible custom output. **Action Stabilization** and **Smart** intentionally use a preview/output split: the live view stays responsive while the saved frame can use extra gyro correction and safety crop. Native Cinematic, Spatial, high-frame-rate, HDR/Log, ProRes and multichannel modes use AVFoundation's native movie path when required; incompatible custom transforms are disabled or grayed rather than faked.

## Apple Camera / AVFoundation parity

HorizonCamera does **not** claim to clone Apple's proprietary image-processing algorithms. The table separates features that can be implemented through public capture APIs from stock-Camera behavior that Apple does not expose as a drop-in API.

### Modes

| Apple Camera area | HorizonCamera status |
|---|---|
| Photo | ✅ Native maximum-quality still capture plus optional custom Horizon/Zoom/filter processing |
| Portrait | ✅ Depth-capable Portrait mode plus **Portrait Lighting approximations** (Natural / Studio / Contour / Stage / Stage Mono / High-Key Mono) driven by the real Portrait Effects matte when available; exact Apple relighting/bokeh is not claimed |
| Video | ✅ Custom stabilized/video-processing path or native AVFoundation path when advanced native features require it |
| Action stabilization | ✅ **Independent tick beside Horizon/Zoom/Smart** using one fixed tuned profile—no strength slider. The custom path applies stronger output-only gyro translation/roll correction and optional native AVFoundation assist. Action is constrained to the public Apple-like envelope up to 2.8K/60 instead of allowing fake 4K/120 combinations |
| Dual Capture | ✅ Separate `AVCaptureMultiCamSession` records simultaneous front + rear cameras with PIP / vertical split / horizontal split layouts |
| Time-lapse | ✅ Frame-sampled time-lapse with configurable interval |
| Slo-mo | ✅ 120 fps and 240 fps when the active iPhone/lens exposes them, retimed for 30 fps playback |
| Cinematic | ✅ Capability-gated public **iOS 26+ Cinematic capture** path, required Cinematic metadata track, and simulated aperture control |
| Spatial | ✅ Capability-gated **Spatial Video** capture through `AVCaptureMovieFileOutput` on supported devices/formats |
| Panorama | ✅ **PANO approximation**: motion/yaw-guided overlapping live-camera frames with FOV-based placement and feathered ImageIO/Core Image stitching |
| Spatial Photo | ✅ Capability-gated stereo HEIC approximation: two simultaneous physical rear-camera streams, factory relative camera extrinsics, matched FOV, stereo-pair group metadata and camera intrinsics/extrinsics |

### Photo capture features

| Feature | Status |
|---|---|
| Live Photo | ✅ Native paired-photo/movie capture on compatible nonprocessed photo settings |
| JPEG / HEIF | ✅ Compatible / efficient output choices |
| Bayer RAW | ✅ When exposed by the camera |
| Apple ProRAW | ✅ Preferred independently from Bayer RAW when `isAppleProRAWSupported` reports support |
| Photo resolution | ✅ Per-shot choices are generated from the active format's real `supportedMaxPhotoDimensions` (for example 12/24/48 MP where the device exposes them), plus Maximum |
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
| 3 s / 5 s / 10 s timer | ✅ Top-screen control |
| Burst lock | ✅ Repeats native still capture as quickly as the real photo output becomes ready; it never invents intermediate captures |
| Output aspect ratios | ✅ 9:16, 16:9, 1:1, 3:4, 4:3, 2:3, 3:2, 4:5, 5:4, 1.85:1 and 2.39:1 on compatible custom paths; native pipelines gray/constrain ratios they cannot actually encode |
| Smart HDR-like / Night-like / Detail Fusion | ✅ **Approximation** using real AVFoundation exposure brackets, optional OIS during bracket capture, exposure normalization, fusion/noise reduction/highlight-shadow/detail processing |
| Photographic Styles | ✅ **Approximation** with Standard / Vibrant / Rich Contrast / Warm / Cool / Rose Gold / Muted plus intensity, tone and warmth controls; not Apple's private rendering recipes |
| Portrait Lighting | ✅ **Approximation** using the delivered Portrait Effects matte for subject/background compositing and relighting-style rendering |

AVFoundation requires long pipeline reconfiguration for depth and semantic mattes, so HorizonCamera configures those at the output/session level rather than setting a cosmetic per-shot flag.

### Video formats and capture

| Feature | Status |
|---|---|
| Frame size | ✅ 720p / 1080p / 2.8K Action / 4K, plus 4224×2240 17:9 and 4224×3024 Open Gate for ProRes RAW when the active device/format exposes them |
| Real-time frame rates | ✅ 23.98 / 24 / 25 / 29.97 / 30 / 48 / 50 / 59.94 / 60 / 100 / 120 / 240 are all represented; unsupported size/lens combinations remain visible but gray. 120/240 in VIDEO remain real-time, distinct from Slo-mo retiming |
| Auto FPS | ✅ iOS 18+ low-light automatic frame-rate control when supported |
| Lock Camera | ✅ Locks constituent-camera switching on supported virtual cameras |
| H.264 | ✅ |
| HEVC | ✅ |
| Apple ProRes 422 LT | ✅ Native movie path when available |
| Apple ProRes 422 | ✅ Native movie path when available |
| Apple ProRes 422 HQ | ✅ Native movie path when available |
| Apple ProRes RAW / RAW HQ | ✅ Public codec choices on iOS/Xcode versions that expose them, capability-gated against active capture formats/output codecs; unsupported combinations stay gray and recording fails closed rather than falling back. Apple requires external storage for ProRes RAW capture on supported iPhones. |
| ProRes RAW Open Gate / 17:9 | ✅ Capability-gated frame-size choices. The external-storage requirement is retained because Apple requires it for ProRes RAW; ordinary ProRes can use internal storage where Apple supports that size/rate combination. |
| SDR / Rec.709 | ✅ Custom writer renders in Rec.709 and tags output consistently |
| HDR / HLG | ✅ Capability-gated native color-space/HDR path |
| Dolby Vision 8.4 / HLG | ✅ Capability-gated native profile requests HEVC Main10 + Rec.2020 HLG and automatic HDR metadata insertion when the output supports those settings; physical-device bitstream/playback validation still applies |
| Apple Log | ✅ Capability-gated native path with compatible HEVC or ProRes; H.264 is grayed/incompatible |
| Apple Log 2 | ✅ iOS 26+ when the active format reports it |
| Native video stabilization | ✅ Off / Standard / Cinematic / Cinematic Extended plus iOS 18/26 modes when the format reports support |
| Action stabilization | ✅ **Fixed-profile tick**. Custom processing is output-only so preview stays low-latency; native assist prefers low-latency/best-supported public stabilization. Action caps incompatible size/FPS choices at an Apple-like 2.8K/60 envelope |
| Dual Capture | ✅ Simultaneous front/rear MultiCam composite recorded through the same tested movie writer |
| Orientation/mirroring metadata track | ✅ Native movie output records changes; portrait/landscape rotation is explicitly configured |
| Native movie digital zoom | ✅ Ramps the **physical capture device**. The main UI uses one transparent logarithmic zoom rail with snap dots for physical lenses instead of separate preset/Auto buttons |
| Still during video | ✅ Separate recording-time still button writes the current saved video frame at video resolution without stopping the recording |
| QuickTake-style recording | ✅ Long-press Photo shutter starts video from the live session; lock keeps it recording after release |

**ProRes RAW note:** Apple requires external storage for ProRes RAW capture on supported iPhones. HorizonCamera does not impose an extra storage rule on formats where Apple allows internal recording. Codec/format choices remain capability-gated and fail closed rather than silently falling back.

**Dolby Vision note:** HorizonCamera now has a separate Dolby Vision 8.4 / HLG-compatible public-API path. It requests HEVC Main10, Rec.2020 HLG and automatic HDR metadata insertion where supported. It still does **not** claim Apple's private Camera tone mapping, ISP decisions, or identical stock-Camera look.

### Focus, exposure and white balance

- Tap focus + tap exposure.
- AE/AF lock.
- Manual focus position on devices that permit lens-position locking.
- Smooth autofocus toggle.
- Face-driven autofocus toggle, configured using Apple's required explicit face-AF state sequence.
- Autofocus range restriction: Full / Near / Far when supported.
- Exposure compensation.
- Manual ISO plus shutter **speed or angle** with camera/format bounds.
- Manual white-balance temperature/tint plus white-balance lock.
- Low-light boost where the device supports it.
- User-facing lens selection is one continuous zoom rail with snap dots for actual physical cameras. Duplicate virtual-camera `Auto` presets are intentionally hidden. Camera flip remains available.

### Audio

- Microphone enable/disable.
- Mono AAC in the custom movie writer.
- Stereo capture through the native input when supported.
- Spatial / first-order ambisonic audio when supported by iOS/device input.
- Wind-noise removal when the input reports support.
- Slo-mo and time-lapse intentionally omit audio because their timelines are remapped.

## Capture metadata

Custom metadata is **off by default**. When enabled, HorizonCamera exposes editable **Title, Author, Copyright, Description and comma-separated Keywords** fields.

With custom metadata disabled, native movies keep AVFoundation/camera metadata without HorizonCamera injecting title/author/software fields. When custom metadata is enabled, the requested QuickTime title/author/copyright/description/keywords/software fields are added. Native orientation/mirroring metadata remains AVFoundation-managed where supported.

Native photos preserve AVFoundation camera metadata. **Processed Horizon/Zoom/filter photos copy the source ImageIO metadata before re-encoding**, preserving EXIF/camera properties; custom TIFF/IPTC fields are injected only when Custom metadata is enabled. Processed HEIC/JPEG uses high-quality encoding rather than a low-quality preview export.

Location metadata is **off by default**. If you enable it, HorizonCamera requests When In Use location permission and embeds a recent fix using the standard ImageIO GPS dictionary for photos and ISO-6709 QuickTime metadata for movies. Diagnostics never include coordinates.

## Viewfinder and camera controls

- Grid (off by default) and level indicator.
- QR-code detection with tap-to-open for HTTP(S), otherwise tap-to-copy.
- Live Text detection runs quietly. A small Live Text button appears only when text exists; the text/copy panel opens only after you tap it, closer to the stock Camera interaction.
- Center Stage toggle on formats that support it.
- iOS 26 Smart Framing monitor: applies the device's recommended dynamic aspect ratio and zoom when supported.
- iOS 26 lens-cleaning hints/status using AVFoundation's camera-lens-smudge detector.
- Main-screen output-aspect menu: 9:16, 16:9, 1:1, 3:4, 4:3, 2:3, 3:2, 4:5, 5:4, 1.85:1 and 2.39:1. Unsupported native combinations stay gray.
- Optional corner **mini overview** (off by default): shows the uncropped active physical lens (ultra-wide at 0.5×, main camera on the 1× path). The yellow capture outline uses the selected real output aspect/crop; with Zoom Lock off it recenters after a point-anchored zoom transition, with Zoom Lock on it floats, sticks at source edges, and regains travel on reversal. With Horizon Lock on, the full lens view can roll underneath while the yellow output frame stays level.
- Main stabilization panel is four independent ticks: **Horizon / Zoom Lock / Action / Smart**. Smart is on by default and adds gentler Super-Steady-style output stabilization plus anti-artifact headroom; Action uses the stronger fixed profile.
- The zoom rail is intentionally compact and transparent, with real physical-lens snap dots instead of separate lens preset buttons/duplicate Auto entries.
- Pinch-to-point zoom: without Zoom Lock, the point under your fingers remains anchored during the zoom transition, then normal framing recenters.
- Floating-frame Zoom Lock reports `Locked` / `Edge`; it is not dependent on Vision recognizing a subject. Its crop window moves inside the full source until it reaches an edge, then regains travel immediately when direction reverses.
- Optional compact wide sensor-view inset, off by default.
- Effective source-crop detail and upscaling warnings.
- Front-camera mirroring control.
- Flash / torch controls.
- Transparent/logarithmic zoom rail with physical-lens snap dots and camera flip; no duplicate `Auto` lens presets.
- Controls remain portrait-oriented while the camera image may roll for Horizon Lock.
- Persistent settings survive relaunch, while the **live zoom always starts at 1×** so a previous zoom/framing position cannot surprise you.
- Active-app **Camera Control** support on iOS 18+: a full press triggers the current shutter/record action, while light-press/slide controls expose HorizonCamera Zoom, native exposure bias, and Manual Focus. These controls are attached to the live `AVCaptureSession`, not decorative UI.

- App chrome follows the iPhone’s current Light/Dark appearance automatically; the camera viewfinder itself stays a neutral black capture canvas. There is no fake chassis/case-color theme.
- First-run permission flow attempts Camera, Microphone, Photos add-only, Location, and Motion sequentially. Location metadata remains off by default even when permission is granted.
- Routine successful saves/deletes are silent; the library only surfaces messages when the user needs to know about a denial or failure. Videos auto-start when opened in the local gallery.

## Approximation boundary — what is still not Apple-identical

HorizonCamera now implements close public-API approximations for several stock-Camera features that do not have a public “use Apple's exact algorithm” API. The approximation is real and affects saved output; the **Apple-identical** behavior below is still not claimed:

- **Night / Smart HDR / detail fusion:** HorizonCamera captures real exposure brackets and fuses them, but it cannot reproduce Apple's private ISP/Neural Engine frame selection, semantic tone mapping, Deep Fusion or exact Night Portrait pipeline.
- **Photographic Styles / Scene Detection:** HorizonCamera provides tunable style recipes and live/saved rendering, but not Apple's proprietary current-generation style engine or automatic scene decisions.
- **Portrait Lighting:** the app uses actual Portrait Effects mattes for relighting-style output, but Apple's exact depth refinement, hair/edge segmentation, relighting and bokeh renderer remain private.
- **Panorama:** PANO performs a real motion-guided feather stitch, but it is not Apple's stock stitcher, exposure optimizer, sweep UI or private geometric correction.
- **Action Stabilization tick:** independent of the mode strip and intentionally has no strength slider. The fixed profile uses stronger output-only timestamp-aligned gyro translation/roll correction while the preview remains low-latency; native assist is capability-gated. Apple's exact stock Action-mode EIS/ISP model remains private.
- **Dolby Vision:** the public path can request a Dolby Vision 8.4 / HLG-compatible HEVC Main10 stream with automatic HDR metadata insertion; Apple's exact Camera HDR tone mapping/look remains private and physical-device validation is required.
- **Spatial Photo:** the app produces a two-image stereo HEIC with factory relative rear-camera extrinsics and spatial metadata, but captures from synchronized camera streams rather than Apple's stock still-fusion pipeline.
- **Dual Capture:** the app really records simultaneous front + rear MultiCam streams and composites them; Apple's iPhone 17 stock UI/heuristics are not cloned.
- **Camera Control:** active-app hardware capture events plus light-press/slide capture controls are implemented. A lock-screen launcher / `LockedCameraCapture` system extension remains a separate entitlement/extension architecture and is not claimed here.
- **Macro Control:** the public virtual camera can switch constituents and physical ultrawide remains selectable, but Apple's private stock Camera macro trigger thresholds/UI are not reproduced.
- **Live Text:** on-device text recognition/copy and QR actions are implemented; the complete system translation/address/phone/currency action surface remains system UI.

This distinction is deliberate: **implemented** means a real code/capture path exists and affects output; **approximation** means HorizonCamera implements the closest public-API behavior without claiming Apple-private algorithms or identical image quality.

## Storage and privacy

Captures are written to `Documents/Captures` first and indexed in a local manifest. If the app is interrupted after a file is created but before the index updates, unindexed JPEG/HEIC/DNG/MOV files are recovered on next launch.

Saving to Apple Photos uses **add-only** authorization. Denied Photos access does not delete the local capture; Share/Files remain available. On first launch the app requests every permission it can legitimately use: **Camera, Microphone, Photos add-only, Location and Motion**. Granting Location does **not** enable location metadata; geotagging remains off until you explicitly turn it on. The app has no account/login requirement and does not upload captures.

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
4. executed iOS tests for rendered pixels, full-turn crop safety, floating Zoom Lock edge/reverse behavior, Action/Smart preview-output separation, mini-overview crop/aspect geometry, Vision utility tracking, encoded movie pixels, audio retiming, Rec.709, processed stills, metadata, expanded formats and settings migration;
5. Release ARM64 iPhone compilation;
6. unsigned IPA structure/platform/privacy/Mach-O verification;
7. artifact upload and GitHub Release publication.

Pull requests run the checks without publishing a release. Successful `main` pushes publish prerelease unsigned IPAs; `v*` tags publish normal releases.

## Architecture

- `Core/` — crop geometry/inverse mapping, floating-frame motion math, horizon estimator, motion interpolation, recording cadence/timeline math.
- `App/CaptureEngine.swift` — serialized AVCaptureSession, physical camera inputs, still output, custom video sample pipeline.
- `App/AdvancedCameraSupport.swift` — native Cinematic / Spatial / ProRes / advanced audio and AVFoundation capability mapping.
- `App/CaptureMetadata.swift` — TIFF/IPTC processed/native photo metadata handling.
- `App/ImagePipeline.swift` — live Horizon/Zoom preview geometry plus a separate output plan for Action/Smart, with timestamp-aligned touch and saved-still mapping.
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
- [Apple: Final Cut Camera recording formats](https://support.apple.com/guide/final-cut-camera/change-video-format-settings-dev9c91a25a9/ios)
- [Blackmagic Design: Blackmagic Camera](https://www.blackmagicdesign.com/products/blackmagiccamera)
- [Samsung: Camera / Super Steady documentation](https://www.samsung.com/us/support/answer/ANS00092462/)

## License / contribution note

This is an independent camera implementation. “Apple”, “iPhone”, “ProRAW”, “ProRes” and related names identify platform technologies/features; “Samsung” identifies the reference feature family discussed above. No proprietary Apple or Samsung camera source code is included.
