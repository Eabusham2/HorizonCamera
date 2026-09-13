import SwiftUI

struct CameraSettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticFile: URL?

    var body: some View {
        NavigationStack {
            Form {
                smartSection
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

    private var smartSection: some View {
        Section("Smart") {
            Text("Smart stabilization is controlled from the main Horizon / Zoom Lock / Action / Smart panel. Lens correction and the camera-aware helpers below stay here.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Lens correction",isOn:model.binding(\.contentAwareDistortionCorrection))
                .disabled(!model.capabilities.contentAwareDistortionCorrection)
            Toggle("Virtual-device fusion",isOn:model.binding(\.virtualDeviceFusion))
                .disabled(!model.capabilities.virtualDeviceFusion)
            Toggle("Sensor orientation compensation",isOn:model.binding(\.sensorOrientationCompensation))
                .disabled(!model.capabilities.sensorOrientationCompensation || model.settings.raw)
            Toggle("Center Stage",isOn:model.binding(\.centerStage))
                .disabled(!model.capabilities.centerStage || model.settings.depthData || model.settings.mode == .portrait)
            Toggle("Smart Framing",isOn:model.binding(\.smartFraming))
                .disabled(!model.capabilities.smartFraming || model.settings.mode == .portrait)
            Toggle("Lens cleaning hints",isOn:model.binding(\.lensCleaningHints))
                .disabled(!model.capabilities.lensSmudgeDetection)
            if model.settings.mode.isMovie {
                Picker("Native stabilization",selection:model.binding(\.stabilization)) {
                    ForEach(StabilizationChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                            .disabled(!model.capabilities.supportedStabilizationModes.contains(choice))
                    }
                }
                .disabled(model.settings.horizonLock || model.settings.zoomLock || model.settings.actionStabilization)
                Toggle("Lock Camera while recording",isOn:model.binding(\.lockCameraSwitching))
                    .disabled(!model.capabilities.lockCameraSwitching)
                Toggle("Auto FPS in low light",isOn:model.binding(\.autoFPS))
                    .disabled(!model.capabilities.autoFPS || model.settings.fps > 60)
                if model.settings.actionStabilization {
                    Toggle("Native Action assist",isOn:model.binding(\.actionNativeAssist))
                    Text("Action assist prefers a low-latency public stabilization mode when the active format supports it. The custom SDR correction remains output-only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stabilizationSection: some View {
        Section("Stabilization") {
            Toggle("Horizon Lock", isOn:model.binding(\.horizonLock))
                .disabled(model.settings.usesNativeMoviePipeline || model.settings.mode == .portrait)
            Toggle("Zoom Lock", isOn:model.binding(\.zoomLock))
                .disabled(model.settings.usesNativeMoviePipeline || model.settings.mode == .portrait || model.settings.actionStabilization)
            Toggle("Action Stabilization", isOn:model.binding(\.actionStabilization))
                .disabled(model.settings.mode != .video)
            if model.settings.actionStabilization {
                Toggle("Native stabilization assist",isOn:model.binding(\.actionNativeAssist))
                Text("Action uses one fixed tuned profile plus the strongest supported public AVFoundation stabilization when Native Assist is enabled. There is no user strength slider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.settings.mode.isMovie {
                Picker("Apple stabilization", selection:model.binding(\.stabilization)) {
                    ForEach(model.capabilities.supportedStabilizationModes) { Text($0.rawValue).tag($0) }
                }.disabled(model.settings.horizonLock || model.settings.zoomLock || model.settings.actionStabilization)
            }
            Button("Reset crop and tracking") { model.resetFraming() }
            Text("Horizon Lock, Zoom Lock and Action Stabilization affect saved output. Action can layer HorizonCamera's gyro/crop correction over the strongest public native stabilization the active format supports. Native Cinematic, Spatial, ProRes/Log and multichannel recording keep AVFoundation's native movie pipeline, so incompatible custom transforms are disabled rather than shown as fake effects.")
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
                if model.capabilities.lockCameraSwitching {
                    Toggle("Lock Camera while recording", isOn:model.binding(\.lockCameraSwitching))
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
                if model.settings.mode == .dualCapture {
                    Picker("Dual layout",selection:model.binding(\.dualCaptureLayout)) { ForEach(DualCaptureLayout.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            Text("Available choices come from the active iPhone lens/format. 25/50 fps appear when supported. ProRes and Apple Log use the native movie path. Dolby Vision 8.4 requests HEVC Main10/Rec.2020 HLG with automatic HDR metadata insertion when the native encoder supports those keys; plain HDR remains HLG.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var photoSection: some View {
        Section("Photos") {
            Picker("Quality priority", selection:model.binding(\.photoQuality)) {
                ForEach(PhotoQualityChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.settings.mode == .photo && model.capabilities.bracketedCapture {
                Picker("Computational photo (approx)",selection:model.binding(\.computationalPhoto)) {
                    ForEach(ComputationalPhotoMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.settings.computationalPhoto != .off {
                    Text("Uses AVFoundation exposure brackets plus HorizonCamera fusion. It approximates Night/Smart HDR/detail fusion; it is not Apple's private ISP/Neural Engine pipeline.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.mode != .panorama && model.settings.mode != .spatialPhoto {
                Picker("Photographic Style (approx)",selection:model.binding(\.photographicStyle)) { ForEach(PhotographicStyleApprox.allCases) { Text($0.rawValue).tag($0) } }
                if model.settings.photographicStyle != .standard || model.settings.hasCustomStyle {
                    LabeledContent("Style intensity",value:String(format:"%.0f%%",model.settings.styleIntensity*100)); Slider(value:model.binding(\.styleIntensity),in:0...1,step:0.05)
                    LabeledContent("Tone",value:String(format:"%+.0f",model.settings.styleTone*100)); Slider(value:model.binding(\.styleTone),in:-1...1,step:0.05)
                    LabeledContent("Warmth",value:String(format:"%+.0f",model.settings.styleWarmth*100)); Slider(value:model.binding(\.styleWarmth),in:-1...1,step:0.05)
                }
            }
            if model.settings.mode == .portrait {
                Picker("Portrait Lighting (approx)",selection:model.binding(\.portraitLighting)) { ForEach(PortraitLightingApprox.allCases) { Text($0.rawValue).tag($0) } }
                LabeledContent("Background blur",value:String(format:"%.0f",model.settings.portraitBlurRadius)); Slider(value:model.binding(\.portraitBlurRadius),in:0...40,step:1)
            }
            if model.settings.mode == .panorama {
                LabeledContent("Stitch feather",value:String(format:"%.0f%%",model.settings.panoramaFeather*100)); Slider(value:model.binding(\.panoramaFeather),in:0.1...0.9,step:0.05)
                Text("PANO is a motion-guided feather stitch from overlapping live camera frames; it approximates the stock panorama workflow rather than Apple's private stitcher.").font(.caption).foregroundStyle(.secondary)
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
            Toggle("Manual exposure",isOn:model.binding(\.manualExposure))
            if model.settings.manualExposure {
                LabeledContent("ISO",value:String(format:"%.0f",model.settings.iso))
                Slider(value:model.binding(\.iso),in:model.capabilities.minISO...max(model.capabilities.minISO+1,model.capabilities.maxISO),step:1)
                Toggle("Use shutter angle",isOn:model.binding(\.shutterAngleMode))
                if model.settings.shutterAngleMode {
                    LabeledContent("Shutter angle",value:String(format:"%.1f°",model.settings.shutterAngle))
                    Slider(value:model.binding(\.shutterAngle),in:1.1...360,step:0.1)
                } else {
                    LabeledContent("Shutter",value:String(format:"1/%.0f s",model.settings.shutterDenominator))
                    Slider(value:model.binding(\.shutterDenominator),in:24...8000,step:1)
                }
            }
            Toggle("Manual white balance",isOn:model.binding(\.manualWhiteBalance))
            if model.settings.manualWhiteBalance {
                LabeledContent("Temperature",value:"\(Int(model.settings.whiteBalanceKelvin)) K")
                Slider(value:model.binding(\.whiteBalanceKelvin),in:2500...10000,step:50)
                LabeledContent("Tint",value:String(format:"%+.0f",model.settings.whiteBalanceTint))
                Slider(value:model.binding(\.whiteBalanceTint),in:-150...150,step:1)
            } else {
                Toggle("Lock white balance",isOn:model.binding(\.whiteBalanceLock))
            }
            Text("Tap the viewfinder to focus/expose. Touch and hold the viewfinder to toggle AE/AF Lock.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var viewfinderSection: some View {
        Section("Viewfinder") {
            Toggle("Grid", isOn:model.binding(\.grid))
            Toggle("Level indicator", isOn:model.binding(\.showLevel))
            Toggle("Mirror front camera", isOn:model.binding(\.mirrorSelfie))
            Toggle("Mini full-lens overview", isOn:model.binding(\.showOverview))
            if model.capabilities.qrScanning { Toggle("Scan QR codes", isOn:model.binding(\.scanQRCodes)) }
            if model.capabilities.liveText { Toggle("Live Text detection",isOn:model.binding(\.showDetectedText)) }
            Text("Live Text detects quietly; the text panel only opens after you tap the Live Text button. Mini overview is off by default and shows the full active lens with the actual output crop in yellow. Grid is off by default. Persistent settings are remembered; live zoom resets to 1× each launch.")
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
        Section("Metadata") {
            Toggle("Custom metadata",isOn:model.binding(\.customMetadataEnabled))
            if model.settings.customMetadataEnabled {
                TextField("Title",text:model.binding(\.metadataTitle))
                TextField("Author",text:model.binding(\.metadataAuthor))
                TextField("Copyright",text:model.binding(\.metadataCopyright))
                TextField("Description",text:model.binding(\.metadataDescription),axis:.vertical)
                TextField("Keywords, comma separated",text:model.binding(\.metadataKeywords))
            }
            Toggle("Location metadata",isOn:model.binding(\.includeLocationMetadata))
            Text("Custom metadata is off by default. With it off, HorizonCamera preserves camera/AVFoundation metadata instead of injecting title/author/software fields. Location is also off until explicitly enabled.")
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
            if model.capabilities.lensSmudgeDetection { LabeledContent("Lens", value:model.diagnostics.lensStatus) }
            if model.capabilities.smartFraming { LabeledContent("Smart framing", value:model.diagnostics.smartFramingStatus) }
            Button("Prepare diagnostic report") { diagnosticFile = model.diagnosticURL() }
            if let diagnosticFile { ShareLink("Share diagnostic JSON", item:diagnosticFile) }
        }
    }

    private var aboutSection: some View {
        Section("About this build") {
            Text("HorizonCamera \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            Text("Native Swift · AVFoundation · Core Motion · Vision · Core Image / Metal")
                .font(.caption).foregroundStyle(.secondary)
            Text("Public/API-backed capture includes native Photo/RAW/ProRAW, real-time and Slo-mo high frame rates, Time-lapse, Cinematic, Spatial Video, ProRes 422/RAW choices when exposed, HLG/Dolby-compatible HDR, Log/Log 2, advanced focus/exposure/WB, Camera Control, Dual Capture and spatial-photo packaging. HorizonCamera also implements real public-API approximations for Action, Night/HDR fusion, Styles, Portrait Lighting and Pano. Apple-private ISP/EIS algorithms and lock-screen Camera replacement behavior are not claimed.")
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
        if model.capabilities.dolbyVision && model.settings.mode == .video { values.append(.dolbyVision84) }
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
