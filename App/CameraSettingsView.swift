import SwiftUI

struct CameraSettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticFile: URL?
    var body: some View {
        NavigationStack {
            Form {
                Section("Stabilization") {
                    Toggle("Horizon Lock",isOn:model.binding(\.horizonLock))
                    Toggle("Zoom Lock",isOn:model.binding(\.zoomLock))
                    Text("Horizon Lock counter-rotates the saved image through full 360° rolls. Its fixed safety crop reduces the field of view. Zoom Lock follows the subject you tap and moves the crop to hold that subject at the tapped screen position.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show wide-view inset",isOn:model.binding(\.showOverview))
                    Button("Reset crop and tracking") { model.resetFraming() }
                    Text("A lost target is not automatically replaced. Tap it again. At a crop boundary, point the phone back toward the subject. Neither lock can recover motion blur or detail outside the sensor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Format") {
                    if model.settings.mode == .photo {
                        Picker("Photo framing",selection:model.binding(\.photoFraming)) {
                            ForEach(Framing.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } else {
                        Picker("Video framing",selection:model.binding(\.videoFraming)) {
                            ForEach(Framing.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Output resolution",selection:model.binding(\.resolution)) {
                            Text("1080p").tag(Resolution.fullHD)
                            Text("4K").tag(Resolution.ultraHD).disabled(!model.capabilities.supports4K)
                        }.disabled(model.settings.mode == .slowMotion)
                        if model.settings.mode == .video {
                            Picker("Frame rate",selection:model.binding(\.fps)) {
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60).disabled(!model.capabilities.supports60)
                            }
                        }
                    }
                    Picker("Encoding",selection:model.binding(\.codec)) {
                        ForEach(CodecChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.settings.mode == .timeLapse {
                        Picker("Capture interval",selection:model.binding(\.timeLapseInterval)) {
                            Text("0.5 seconds").tag(0.5);Text("1 second").tag(1.0);Text("2 seconds").tag(2.0);Text("5 seconds").tag(5.0)
                        }
                    }
                    Text("Video is SDR. 4K is the output canvas size, not a promise of 4K detail after stabilization. The viewfinder warns when pixels are upscaled. Slo-mo captures 120 fps and plays at 30 fps; time-lapse and slo-mo omit audio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Photos") {
                    Picker("Shutter timer",selection:model.binding(\.timer)) {
                        Text("Off").tag(0);Text("3 seconds").tag(3);Text("10 seconds").tag(10)
                    }
                    Toggle("Live Photo",isOn:model.binding(\.livePhoto))
                        .disabled(!model.capabilities.livePhoto || model.settings.isProcessedPhoto)
                    Toggle("RAW + processed photo",isOn:model.binding(\.raw))
                        .disabled(!model.capabilities.raw || model.settings.isProcessedPhoto)
                    Text("Native Live Photos and RAW are available only with both locks off, digital zoom at 1×, Original filter, and 3:4 framing. RAW and Live Photo are mutually exclusive; enabling one turns the other off. Their original sensor data and paired video are not silently substituted for stabilized output. Native maximum-quality stills are used when no processing is requested.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Filter",selection:model.binding(\.filter)) {
                        ForEach(CaptureFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                exposureSection
                Section("Viewfinder") {
                    Toggle("Grid",isOn:model.binding(\.grid))
                    Toggle("Level indicator",isOn:model.binding(\.showLevel))
                    Toggle("Mirror front camera",isOn:model.binding(\.mirrorSelfie))
                    Text("The controls stay upright in portrait so rolling the phone cannot change the recording layout. Select 16:9 for a landscape file or 9:16 for a portrait file before recording. Tap to focus/track; pinch to zoom around your fingers; hold to toggle AE/AF lock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Audio and saving") {
                    Toggle("Record microphone",isOn:Binding(get:{ model.settings.audio },set:{ model.enableAudio($0) }))
                    Toggle("Also save to Photos",isOn:model.binding(\.saveToPhotos))
                    Text("Captures are always retained in this app first. When Photos permission is denied, recordings remain in the library and can be shared or saved using Files. Nothing is uploaded, and no account is required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Calibration and diagnostics") {
                    LabeledContent("Horizon trim",value:String(format:"%+.1f°",model.settings.horizonTrimDegrees))
                    Slider(value:model.binding(\.horizonTrimDegrees),in:-10...10,step:0.1)
                    LabeledContent("Motion offset",value:String(format:"%+.0f ms",model.settings.motionOffsetMilliseconds))
                    Slider(value:model.binding(\.motionOffsetMilliseconds),in:-50...50,step:1)
                    Text("Leave both at zero unless a physical-device test shows a consistent alignment/timing offset. Looking directly up or down makes the gravity-defined horizon ambiguous; the app reports gyro hold rather than claiming a reliable level.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Source",value:model.capabilities.sourceDescription)
                    LabeledContent("Delivered frames",value:String(format:"%.1f fps",model.diagnostics.deliveredFPS))
                    LabeledContent("Dropped frames",value:"\(model.diagnostics.droppedFrames)")
                    LabeledContent("Source crop detail",value:"\(Int(model.diagnostics.detail.width))×\(Int(model.diagnostics.detail.height)) px")
                    LabeledContent("Motion",value:model.diagnostics.motionStatus)
                    LabeledContent("Tracking",value:model.diagnostics.trackingStatus)
                    LabeledContent("Vision confidence",value:String(format:"%.0f%%",model.diagnostics.confidence*100))
                    Button("Prepare diagnostic report") { diagnosticFile = model.diagnosticURL() }
                    if let diagnosticFile { ShareLink("Share diagnostic JSON",item:diagnosticFile) }
                }
                Section("About this build") {
                    Text("HorizonCamera \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    Text("Native Swift · AVFoundation · Core Motion · Vision · Core Image / Metal")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("This is an independent implementation, not Samsung's proprietary algorithm or a clone of Apple's entire Camera app. Night mode fusion, Portrait depth effects, Cinematic depth recording, Panorama, Apple photographic styles, ProRes and Dolby Vision are not implemented in this build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!model.canConfigure)
            .navigationTitle("Camera settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { model.persist(); dismiss() } } }
        }.tint(.yellow)
    }
    private var exposureSection: some View {
        Section("Focus and exposure") {
            Toggle("AE/AF lock",isOn:model.binding(\.aeafLock))
            LabeledContent("Exposure compensation",value:String(format:"%+.1f EV",model.settings.exposureEV))
            Slider(value:model.binding(\.exposureEV),in:model.capabilities.minEV...max(model.capabilities.minEV+0.1,model.capabilities.maxEV),step:0.1)
                .disabled(model.settings.manualExposure || model.settings.aeafLock)
            Toggle("Manual focus",isOn:model.binding(\.manualFocus)).disabled(!model.capabilities.manualFocus)
            if model.settings.manualFocus {
                Slider(value:model.binding(\.lensPosition),in:0...1).accessibilityLabel("Lens focus position")
                HStack { Text("Near");Spacer();Text("Far") }.font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Manual exposure",isOn:model.binding(\.manualExposure))
            if model.settings.manualExposure {
                LabeledContent("ISO",value:String(format:"%.0f",model.settings.iso))
                Slider(value:model.binding(\.iso),in:model.capabilities.minISO...max(model.capabilities.minISO+1,model.capabilities.maxISO),step:1)
                LabeledContent("Shutter",value:String(format:"1/%.0f s",model.settings.shutterDenominator))
                Slider(value:model.binding(\.shutterDenominator),in:30...4000,step:5)
                Text("Requested ISO and shutter are clamped to this lens/format and frame interval.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Lock white balance",isOn:model.binding(\.whiteBalanceLock))
        }
    }
}
