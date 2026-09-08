# Architecture and invariants

## Coordinate system and one transform

AVFoundation supplies fixed-portrait video buffers. Mirroring is explicit. All processing geometry uses lower-left-origin source pixels; UIKit touch locations are converted from upper-left coordinates. Preview, export, overview crop outline and inverse touch mapping share a `CropPlan` rather than independent approximations.

For output size `(Wo,Ho)` and source `(Ws,Hs)`, full-turn mode uses:

```
scale = hypot(Wo,Ho) / min(Ws,Hs) * digitalZoom / reserve
outputPoint = scale * R(angle) * (sourcePoint - cropCenter) + outputCenter
```

The constant full-turn scale inscribes the output rectangle's circumscribed circle in the source. It is deliberately conservative. It prevents angle-dependent zoom breathing and black corners, but cannot retain the full native field of view.

The axis-aligned footprint of the inverse-rotated output determines legal crop centers:

```
halfX = (abs(cos(angle))*Wo + abs(sin(angle))*Ho) / (2*scale)
halfY = (abs(sin(angle))*Wo + abs(cos(angle))*Ho) / (2*scale)
center.x in [halfX, Ws-halfX]
center.y in [halfY, Hs-halfY]
```

Zoom Lock reserves additional crop headroom (`reserve=0.80`). Horizon-only reserves 0.97. Without locks, reserve is 1. Crop boundaries are reported rather than hidden by a stretch or fake target lock.

## Sensor timing

Core Motion samples processed gravity/rotation into a bounded, locked history. The requested rate is 200 Hz; actual delivery is controlled by iOS/device. Camera timestamps are converted from the capture session's synchronization clock into host time, then used to interpolate motion. Processing does not simply attach the newest attitude to an older buffered frame.

Rear-camera correction is `-atan2(gravity.x, -gravity.y)`, with continuous angle unwrapping. An unmirrored front camera reverses the camera-plane X sign. Near a vertical viewing direction, projected gravity becomes ill-conditioned; hysteresis switches to short-term gyro continuation and the UI explicitly reports it. Stale samples freeze the last correction with a warning. A configurable, initially zero motion offset and horizon trim support physical-device calibration.

Native electronic stabilization is disabled with custom locks because it can introduce its own time-varying image transform and latency. There is no claim of reverse-engineered Samsung processing, synchronized rolling-shutter correction, multi-camera computational fusion, gimbal behavior or complete optical/IMU calibration.

## Subject-based Zoom Lock

A tap is inverse-mapped from the visible processed image into a region of the source image. `VNTrackObjectRequest` follows that region using a sequence handler. Vision receives a downscaled source image, capped at 1280 pixels on its long edge and approximately 30 updates per second.

For the tracked source point `p` and chosen normalized output anchor `a`:

```
requestedCenter = p - R(-angle) * (a * outputSize - outputCenter) / scale
```

The legal crop center is clamped to the available sensor footprint. The subject is not forced to the middle when the user chose an off-center screen position. Pinch-to-point zoom uses the same inverse mapping when subject tracking is disabled.

Confidence below 0.35 increments a miss counter; three misses lose the target. An implausibly large normalized center jump loses it immediately. A lost request is terminated and is not silently reseeded to another object. This is region tracking, not a guarantee of semantic identity through full occlusion. Tap to reacquire. Edge and loss are independent of the checkbox being enabled.

## Rendering and recording

Core Image renders through Metal. `PreviewFeed` retains only the latest frame; UI lag does not create an unbounded queue of camera buffers. `AVAssetWriterInputPixelBufferAdaptor` receives the same processed image as the viewfinder. Its pixel buffer pool has a bounded allocation threshold and encoder backpressure is counted. Output is SDR HEVC or H.264; unsupported HEVC encoding falls back to H.264.

Normal video and AAC microphone timing share the first accepted video frame's capture timestamp as origin. Earlier microphone packets are excluded, subsequent timestamps are shifted without independent wall-clock origins. Slo-mo stretches 120-fps source times to 30-fps playback. Time-lapse actually samples frames at the chosen interval and assigns consecutive 30-fps presentation times. These two modes omit audio rather than producing mislabeled or desynchronized audio.

Without Horizon Lock, recording framing is frozen before capture; rotating the phone does not switch the file between two landscape orientations midway through a take.

## Photos and native extras

Native unprocessed stills use `AVCapturePhotoOutput` and preserve full-resolution encoded data. Processed stills use the native photo exposure timestamp and recent render-plan history. The still's center region is normalized to the video-source aspect before applying the lock/crop. Effective output resolution is derived from the available crop rather than enlarging it to advertise native still resolution. Exact optical FOV matching across photo/video formats remains a device-validation item.

Live Photo and RAW are native-only while custom processing is off. The app retains the original paired movie or DNG and exports those actual resources. It does not imply that a modified still plus an unmodified native paired movie is a stabilized Live Photo.

## Ownership and lifecycle

The capture session and device mutations belong to one serial session queue. Frames, tracking, geometry and the writer belong to one serial frame queue. User-facing state is delivered on the main queue. Configuration is disabled while recording/finalizing/capturing a photo; zoom and target selection remain available while recording.

Camera/audio interruptions finish a recording when possible. Background transitions request a short iOS background task to finish saving, not to keep covertly recording. Critical heat and low free storage stop capture. Empty recordings are rejected. All media is first written to the app's Documents/Captures directory, then optionally exported with add-only Photos permission. Denied Photos access leaves the local capture available. Local deletion never deletes the Photos copy. Unindexed local captures can be recovered on relaunch.

## Build trust

No external Swift packages, API keys, analytics or runtime network requests. Signing assets are excluded from source control. The release workflow requires passing automated gates and verifies the archive's ARM64 iPhoneOS executable and absence of code-signature/provisioning material. It cannot certify a physical lens, microphone, IMU alignment or thermal performance.
