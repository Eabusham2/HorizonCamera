import SwiftUI

struct CameraSettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticFile: URL?

    var body: some View {
        NavigationStack {
            Form {
                stabilizationSection
                formatSection
                if model.settings.mode.isPhotoMode { photoSection }
                focusExposureSection
                viewfinderSection
                if model.settings.mode.isMovie { audioSection }
                metadataSection
                savingSection
                diagnosticsSection
                aboutSection
            }
            .disabled(!model.canConfigure)
            .navigationTitle("Camera settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { model.persist(); dismiss() } } }
        }.tint(.yellow)
    }

    private var stabilizationSection: some View {
        Section("Stabilization") {
            Toggle("Horizon Lock", isOn:model.binding(\.horizonLock))
                .disabled(model.settings.usesNativeMoviePipeline || model.settings.mode == .portrait)
            Toggle("Zoom Lock", isOn:model.binding(\.zoomLock))
                .disabled(model.settings.usesNativeMoviePipeline || model.settings.mode == .portrait)
            if model.settings.mode.isMovie {
                Picker("Apple stabilization", selection:model.binding(\.stabilization)) {
                    ForEach(model.capabilities.supportedStabilizationModes) { Text($0.rawValue).tag($0) }
                }.disabled(model.settings.horizonLock || model.settings.zoomLock)
            }
            Toggle("Show wide-view inset", isOn:model.binding(\.showOverview))
            Button("Reset crop and tracking") { model.resetFraming() }
            Text("Horizon Lock and Zoom Lock are custom pixel transforms and affect saved output. Native Cinematic, Spatial, ProRes/Log and multichannel recording keep AVFoundation's native movie pipeline, so custom locks are disabled there instead of pretending they were applied.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var formatSection: some View {
        Section("Format") {
            if model.settings.mode.isPhotoMode {
                Picker("Photo framing", selection:model.binding(\.photoFraming)) {
                    ForEach(Framing.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(model.settings.mode == .portrait)
            } else {
                Picker("Video framing", selection:model.binding(\.videoFraming)) {
                    ForEach(Framing.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Resolution", selection:model.binding(\.resolution)) {
                    ForEach(model.capabilities.supportedResolutions) { Text($0.rawValue).tag($0) }
                }
                if model.settings.mode == .slowMotion {
                    Picker("Slow-motion capture", selection:model.binding(\.slowMotionFPS)) {
                        ForEach(model.capabilities.supportedSlowMotionFPS, id:\.self) { Text("\($0) fps").tag($0) }
                    }
                } else if model.settings.mode != .timeLapse {
                    Picker("Frame rate", selection:model.binding(\.fps)) {
                        ForEach(model.capabilities.supportedFPS, id:\.self) { Text("\($0) fps").tag($0) }
                    }
                    if model.capabilities.autoFPS { Toggle("Auto FPS in low light", isOn:model.binding(\.autoFPS)) }
                }
                Picker("Encoding", selection:model.binding(\.codec)) {
                    ForEach(availableCodecs) { Text($0.rawValue).tag($0) }
                }
                Picker("Color profile", selection:model.binding(\.colorProfile)) {
                    ForEach(availableColorProfiles) { Text($0.rawValue).tag($0) }
                }.disabled(model.settings.mode == .slowMotion || model.settings.mode == .timeLapse || model.settings.mode == .spatial)
                if model.settings.mode == .cinematic {
                    LabeledContent("Simulated aperture", value:String(format:"f/%.1f",model.settings.cinematicAperture))
                    Slider(value:model.binding(\.cinematicAperture), in:1.2...16, step:0.1)
                }
                if model.settings.mode == .timeLapse {
                    Picker("Capture interval", selection:model.binding(\.timeLapseInterval)) {
                        Text("0.5 seconds").tag(0.5); Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                    }
                }
            }
            Text("Available choices come from the active iPhone lens/format. 25/50 fps appear when supported. ProRes and Apple Log use the native movie path. HDR here is HLG; it is not a claim of Apple's Dolby Vision Camera pipeline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var photoSection: some View {
        Section("Photos") {
            Picker("Shutter timer", selection:model.binding(\.timer)) {
                Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10)
            }
            Picker("Quality priority", selection:model.binding(\.photoQuality)) {
                ForEach(PhotoQualityChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Live Photo", isOn:model.binding(\.livePhoto))
                .disabled(!model.capabilities.livePhoto || model.settings.isProcessedPhoto || model.settings.mode == .portrait || model.settings.constantColor)
            Toggle("RAW + processed photo", isOn:model.binding(\.raw))
                .disabled(!model.capabilities.raw || model.settings.isProcessedPhoto || model.settings.mode == .portrait || model.settings.constantColor)
            if model.settings.raw && model.capabilities.proRAW {
                Toggle("Prefer Apple ProRAW", isOn:model.binding(\.preferProRAW))
            }
            Picker("Filter", selection:model.binding(\.filter)) {
                ForEach(CaptureFilter.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(model.settings.mode == .portrait)

            if model.capabilities.depthData {
                Toggle("Depth data", isOn:model.binding(\.depthData)).disabled(model.settings.raw || model.settings.isProcessedPhoto || model.settings.mode == .portrait)
                if model.settings.depthData {
                    Toggle("Filter depth data", isOn:model.binding(\.depthDataFiltered))
                    if model.capabilities.portraitEffectsMatte {
                        Toggle("Portrait Effects matte", isOn:model.binding(\.portraitEffectsMatte)).disabled(model.settings.mode == .portrait)
                    }
                }
            }
            if model.capabilities.semanticMattes {
                Toggle("Semantic segmentation mattes", isOn:model.binding(\.semanticMattes)).disabled(model.settings.raw || model.settings.isProcessedPhoto)
            }
            if model.capabilities.constantColor {
                Toggle("Constant Color", isOn:model.binding(\.constantColor)).disabled(model.settings.raw || model.settings.isProcessedPhoto || model.settings.mode == .portrait)
                if model.settings.constantColor { Toggle("Constant Color fallback photo", isOn:model.binding(\.constantColorFallback)) }
            }
            if model.capabilities.autoRedEyeReduction { Toggle("Auto red-eye reduction", isOn:model.binding(\.autoRedEyeReduction)) }
            if model.capabilities.contentAwareDistortionCorrection { Toggle("Content-aware distortion correction", isOn:model.binding(\.contentAwareDistortionCorrection)) }
            if model.capabilities.virtualDeviceFusion { Toggle("Automatic virtual-device fusion", isOn:model.binding(\.virtualDeviceFusion)) }
            if model.capabilities.sensorOrientationCompensation { Toggle("Sensor-orientation compensation", isOn:model.binding(\.sensorOrientationCompensation)).disabled(model.settings.raw) }
            if model.capabilities.cameraCalibrationData { Toggle("Camera calibration data", isOn:model.binding(\.cameraCalibrationData)).disabled(model.settings.raw) }

            if model.capabilities.responsiveCapture { Toggle("Responsive capture", isOn:model.binding(\.responsiveCapture)) }
            if model.capabilities.zeroShutterLag { Toggle("Zero shutter lag", isOn:model.binding(\.zeroShutterLag)) }
            if model.capabilities.fastCapturePrioritization { Toggle("Prioritize faster shooting", isOn:model.binding(\.fastCapturePrioritization)) }
            if model.capabilities.autoDeferredPhotoDelivery { Toggle("Automatic deferred photo delivery", isOn:model.binding(\.autoDeferredPhotoDelivery)) }

            Text(model.settings.mode == .portrait
                 ? "Portrait captures AVFoundation depth and Portrait Effects matte data in the photo when the device supports them. It does not fake Apple's proprietary Portrait Lighting or stock Camera blur rendering."
                 : "Depth, portrait and semantic mattes are embedded in compatible HEIF/JPEG output. RAW, Live Photo, Constant Color and custom pixel transforms are constrained when AVFoundation combinations are incompatible.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var focusExposureSection: some View {
        Section("Focus and exposure") {
            Toggle("AE/AF lock", isOn:model.binding(\.aeafLock))
            LabeledContent("Exposure compensation", value:String(format:"%+.1f EV",model.settings.exposureEV))
            Slider(value:model.binding(\.exposureEV), in:model.capabilities.minEV...max(model.capabilities.minEV+0.1,model.capabilities.maxEV), step:0.1)
                .disabled(model.settings.manualExposure || model.settings.aeafLock)
            Toggle("Manual focus", isOn:model.binding(\.manualFocus)).disabled(!model.capabilities.manualFocus)
            if model.settings.manualFocus {
                Slider(value:model.binding(\.lensPosition), in:0...1).accessibilityLabel("Lens focus position")
                HStack { Text("Near"); Spacer(); Text("Far") }.font(.caption).foregroundStyle(.secondary)
            } else {
                if model.capabilities.smoothAutofocus { Toggle("Smooth autofocus", isOn:model.binding(\.smoothAutofocus)) }
                if model.capabilities.faceDrivenAutofocus { Toggle("Face-driven autofocus", isOn:model.binding(\.faceDrivenAutofocus)) }
                if model.capabilities.focusRangeRestriction {
                    Picker("Autofocus range", selection:model.binding(\.focusRange)) { ForEach(FocusRangeChoice.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            Toggle("Manual exposure", isOn:model.binding(\.manualExposure))
            if model.settings.manualExposure {
                LabeledContent("ISO", value:String(format:"%.0f",model.settings.iso))
                Slider(value:model.binding(\.iso), in:model.capabilities.minISO...max(model.capabilities.minISO+1,model.capabilities.maxISO), step:1)
                LabeledContent("Shutter", value:String(format:"1/%.0f s",model.settings.shutterDenominator))
                Slider(value:model.binding(\.shutterDenominator), in:30...4000, step:5)
            }
            Toggle("Lock white balance", isOn:model.binding(\.whiteBalanceLock))
        }
    }

    private var viewfinderSection: some View {
        Section("Viewfinder") {
            Toggle("Grid", isOn:model.binding(\.grid))
            Toggle("Level indicator", isOn:model.binding(\.showLevel))
            Toggle("Mirror front camera", isOn:model.binding(\.mirrorSelfie))
            Text("Tap to focus/expose, pinch to zoom around the touched point, and hold to toggle AE/AF lock. Settings are persisted by HorizonCamera between launches.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Record microphone", isOn:Binding(get:{ model.settings.audio }, set:{ model.enableAudio($0) }))
            if model.settings.audio {
                Picker("Audio capture", selection:model.binding(\.audioMode)) {
                    ForEach(availableAudioModes) { Text($0.rawValue).tag($0) }
                }
                if model.capabilities.windNoiseRemoval { Toggle("Wind-noise removal", isOn:model.binding(\.windNoiseRemoval)) }
            }
            Text("Stereo and Spatial/Ambisonic audio are offered only when the active input reports support. Selecting them uses the native AVFoundation movie path.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metadataSection: some View {
        Section("Capture metadata") {
            TextField("Title", text:model.binding(\.metadataTitle))
            TextField("Author", text:model.binding(\.metadataAuthor))
            TextField("Copyright", text:model.binding(\.metadataCopyright))
            TextField("Description", text:model.binding(\.metadataDescription), axis:.vertical)
            TextField("Keywords, comma separated", text:model.binding(\.metadataKeywords))
            Toggle("Location metadata", isOn:model.binding(\.includeLocationMetadata))
            Text("Location is off by default. When enabled, iOS requests When In Use permission and a recent location is embedded as standard GPS/ISO-6709 metadata; the diagnostic report never includes coordinates.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Native movies receive QuickTime title/author/copyright/description/keywords, software and creation-date metadata. Native and processed photos receive standardized TIFF/IPTC metadata; EXIF camera properties remain AVFoundation-managed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savingSection: some View {
        Section("Saving") {
            Toggle("Also save to Photos", isOn:model.binding(\.saveToPhotos))
            Text("Captures are retained in HorizonCamera's local library first. Photos permission is add-only; the app does not read your existing library or upload captures.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section("Calibration and diagnostics") {
            LabeledContent("Horizon trim", value:String(format:"%+.1f°",model.settings.horizonTrimDegrees))
            Slider(value:model.binding(\.horizonTrimDegrees), in:-10...10, step:0.1)
            LabeledContent("Motion offset", value:String(format:"%+.0f ms",model.settings.motionOffsetMilliseconds))
            Slider(value:model.binding(\.motionOffsetMilliseconds), in:-50...50, step:1)
            LabeledContent("Source", value:model.capabilities.sourceDescription)
            LabeledContent("Delivered frames", value:String(format:"%.1f fps",model.diagnostics.deliveredFPS))
            LabeledContent("Dropped frames", value:"\(model.diagnostics.droppedFrames)")
            LabeledContent("Source crop detail", value:"\(Int(model.diagnostics.detail.width))×\(Int(model.diagnostics.detail.height)) px")
            LabeledContent("Motion", value:model.diagnostics.motionStatus)
            LabeledContent("Tracking", value:model.diagnostics.trackingStatus)
            LabeledContent("Vision confidence", value:String(format:"%.0f%%",model.diagnostics.confidence*100))
            Button("Prepare diagnostic report") { diagnosticFile = model.diagnosticURL() }
            if let diagnosticFile { ShareLink("Share diagnostic JSON", item:diagnosticFile) }
        }
    }

    private var aboutSection: some View {
        Section("About this build") {
            Text("HorizonCamera \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            Text("Native Swift · AVFoundation · Core Motion · Vision · Core Image / Metal")
                .font(.caption).foregroundStyle(.secondary)
            Text("Implemented public-API paths include Photo, depth-based Portrait data, Video, Time-lapse, Slo-mo, Cinematic, Spatial Video, ProRAW/RAW, ProRes, HLG HDR, Apple Log/Log 2, native stabilization choices and advanced audio. Apple's exact Night fusion, Photographic Styles, Portrait Lighting, Panorama stitching, Dolby Vision Camera look, Action-mode algorithm, Spatial Photo capture, Camera Control hardware behavior and lock-screen Camera extension are not claimed or imitated.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var availableCodecs: [CodecChoice] {
        if model.settings.mode.isPhotoMode { return [.efficient,.compatible] }
        var values: [CodecChoice] = [.efficient,.compatible]
        if model.capabilities.proRes && model.settings.mode == .video {
            values += [.proResLT,.proRes422,.proResHQ]
        }
        return values
    }
    private var availableColorProfiles: [VideoColorProfile] {
        var values: [VideoColorProfile] = [.sdr]
        if model.capabilities.hdrHLG && model.settings.mode == .video { values.append(.hdrHLG) }
        if model.capabilities.proRes && model.settings.mode == .video {
            if model.capabilities.appleLog { values.append(.appleLog) }
            if model.capabilities.appleLog2 { values.append(.appleLog2) }
        }
        return values
    }
    private var availableAudioModes: [AudioCaptureMode] {
        var values: [AudioCaptureMode] = [.mono]
        if model.capabilities.stereoAudio { values.append(.stereo) }
        if model.capabilities.spatialAudio { values.append(.spatial) }
        return values
    }
}
