from pathlib import Path
import re


def rep(path, old, new, count=1):
    p=Path(path); s=p.read_text(); n=s.count(old)
    if n < count: raise SystemExit(f"{path}: need {count} match(es), found {n}: {old!r}")
    p.write_text(s.replace(old,new,count))


def sub1(path, pattern, replacement, flags=0):
    p=Path(path); s=p.read_text(); out,n=re.subn(pattern,replacement,s,count=1,flags=flags)
    if n != 1: raise SystemExit(f"{path}: expected 1 regex match, got {n}: {pattern}")
    p.write_text(out)


# MARK: CameraView state + top-level reason UI
rep('App/CameraView.swift',
    '    @State private var showModeTip = false\n    @State private var quickTakeTriggered = false\n',
    '    @State private var showQuickControls = false\n    @State private var quickTakeTriggered = false\n')

# Add quick-controls toggle to the top bar and keep full settings for rare/advanced controls.
rep('App/CameraView.swift',
    '            Button { model.showSettings=true } label: { Image(systemName:"gearshape") }\n                .disabled(model.isRecording || model.busy)\n',
    '            Button { withAnimation(.easeInOut(duration:0.15)) { showQuickControls.toggle() } } label: {\n                Image(systemName:showQuickControls ? "chevron.up.circle.fill":"chevron.down.circle")\n            }\n            .accessibilityLabel("Camera controls")\n            Button { model.showSettings=true } label: { Image(systemName:"gearshape") }\n                .disabled(model.isRecording || model.busy)\n')

# Menus show why an entry is gray, rather than silently changing a different setting.
sub1('App/CameraView.swift',
     r'    private var hdrControl: some View \{.*?\n    \}\n    private var formatControl:',
     '''    private var hdrControl: some View {
        Menu {
            Section("Color") {
                ForEach(VideoColorProfile.allCases) { profile in
                    let reason=colorProfileUnavailableReason(profile)
                    Button(reason == nil ? profile.rawValue : "\\(profile.rawValue) — \\(reason!)") {
                        if reason == nil { model.notice=nil; model.selectColorProfile(profile) }
                    }
                    .disabled(reason != nil)
                }
            }
            Text("Gray choices include the reason they are unavailable for this camera/format.")
        } label: {
            Text(model.settings.colorProfile.isHDR ? "HDR":"SDR")
                .font(.system(size:11,weight:.bold)).foregroundStyle(model.settings.colorProfile.isHDR ? .yellow:.white)
        }
    }
    private var formatControl:''', re.S)

sub1('App/CameraView.swift',
     r'    private var formatControl: some View \{.*?\n    \}\n    private var aspectControl:',
     '''    private var formatControl: some View {
        Menu {
            Section("Codec") {
                ForEach(CodecChoice.allCases) { codec in
                    let reason=codecUnavailableReason(codec)
                    Button(reason == nil ? codec.rawValue : "\\(codec.rawValue) — \\(reason!)") {
                        if reason == nil { model.notice=nil; model.selectCodec(codec) }
                    }
                    .disabled(reason != nil)
                }
            }
            if model.settings.mode.isMovie {
                Section("Frame Size") {
                    ForEach(Resolution.allCases) { resolution in
                        let reason=resolutionUnavailableReason(resolution)
                        Button(reason == nil ? resolutionLabel(resolution) : "\\(resolutionLabel(resolution)) — \\(reason!)") {
                            if reason == nil { model.notice=nil; model.selectResolution(resolution) }
                        }
                        .disabled(reason != nil)
                    }
                }
                Section("Frame Rate") {
                    ForEach(FrameRateCatalog.all,id:\\.self) { rate in
                        let reason=frameRateUnavailableReason(rate)
                        Button(reason == nil ? "\\(FrameRateCatalog.label(rate)) fps" : "\\(FrameRateCatalog.label(rate)) fps — \\(reason!)") {
                            if reason == nil { model.notice=nil; model.selectFrameRate(rate) }
                        }
                        .disabled(reason != nil)
                    }
                }
            } else if !model.capabilities.supportedPhotoResolutionsMP.isEmpty {
                Section("Photo Resolution") {
                    Button("Maximum · \\(model.capabilities.supportedPhotoResolutionsMP.max().map(String.init) ?? "?") MP") { model.change{$0.photoResolutionMP=0} }
                    ForEach(model.capabilities.supportedPhotoResolutionsMP,id:\\.self) { mp in
                        Button("\\(mp) MP") { model.change{$0.photoResolutionMP=mp} }
                    }
                }
            }
            Text(model.isFrontCamera ? "Choices are for the active front camera." : "Choices are for the active rear camera.")
        } label: {
            VStack(spacing:0) {
                Text(formatLabel).font(.system(size:10,weight:.bold,design:.rounded))
                if model.settings.mode.isMovie { Text("FORMAT").font(.system(size:7,weight:.medium)) }
            }
        }
        .disabled(!model.canConfigure)
    }
    private var aspectControl:''', re.S)

sub1('App/CameraView.swift',
     r'    private var aspectControl: some View \{.*?\n    \}\n\n    private var viewfinder:',
     '''    private var aspectControl: some View {
        Menu {
            Section("Output Aspect") {
                ForEach(Framing.allCases) { framing in
                    let reason=framingUnavailableReason(framing)
                    Button(reason == nil ? framing.rawValue : "\\(framing.rawValue) — \\(reason!)") {
                        guard reason == nil else { return }
                        model.notice=nil
                        model.change {
                            if $0.mode.isPhotoMode { $0.photoFraming = framing }
                            else { $0.videoFraming = framing }
                        }
                    }
                    .disabled(reason != nil)
                }
            }
            Text("The mini overview yellow frame matches the selected real output crop.")
        } label: {
            Text(model.settings.framing.rawValue).font(.system(size:10,weight:.bold,design:.rounded))
        }
        .disabled(!model.canConfigure || model.settings.mode.isStandaloneCaptureMode)
    }

    private var viewfinder:''', re.S)

# Auto-visible Live Text chip + optional stats overlay. No blue info button gate.
rep('App/CameraView.swift',
    '''                            if model.settings.aeafLock { Text("AE/AF LOCK").font(.caption2.bold()).foregroundStyle(.yellow) }
                            Spacer()
                            if model.settings.showOverview {''',
    '''                            VStack(alignment:.leading,spacing:4) {
                                if model.settings.aeafLock { Text("AE/AF LOCK").font(.caption2.bold()).foregroundStyle(.yellow) }
                                if model.settings.showStats {
                                    VStack(alignment:.leading,spacing:1) {
                                        Text(String(format:"%.1f FPS",model.diagnostics.deliveredFPS))
                                        Text("DROP \\(model.diagnostics.droppedFrames)")
                                        Text(model.diagnostics.trackingStatus.uppercased())
                                    }
                                    .font(.system(size:8,weight:.semibold,design:.monospaced))
                                    .padding(.horizontal,6).padding(.vertical,4)
                                    .background(.black.opacity(0.55),in:RoundedRectangle(cornerRadius:6))
                                }
                            }
                            Spacer()
                            if model.settings.showOverview {''')

sub1('App/CameraView.swift',
     r'                        HStack\(alignment:\.bottom\) \{\n                            if model\.diagnostics\.upscaled \{.*?\n                            \}\n                        \}\n                        ZoomRail',
     '''                        HStack(alignment:.bottom) {
                            if model.diagnostics.upscaled { Image(systemName:"exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow) }
                            Spacer()
                            if model.settings.showDetectedText && !model.detectedText.isEmpty {
                                Button { withAnimation(.easeInOut(duration:0.15)) { showLiveTextPanel.toggle() } } label: {
                                    HStack(spacing:5) {
                                        Image(systemName:"text.viewfinder")
                                        Text(model.detectedText.first ?? "Text").lineLimit(1)
                                    }
                                    .font(.caption2.bold()).foregroundStyle(.white)
                                    .padding(.horizontal,8).padding(.vertical,6)
                                    .background(.black.opacity(0.62),in:Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Live Text: \\(model.detectedText.first ?? "detected text")")
                            }
                        }
                        ZoomRail''', re.S)

# Main control area: quick controls, scrollable lock row, stable LazyHStack modes, no info.circle.
sub1('App/CameraView.swift',
     r'    private var controls: some View \{.*?\n    \}\n\n    private var shutterRow:',
     '''    private var controls: some View {
        VStack(spacing:6) {
            if showQuickControls { quickControls }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    lockButton("Horizon",icon:"gyroscope",enabled:model.settings.horizonLock,
                               disabledReason:horizonDisabledReason) { model.change{$0.horizonLock.toggle()} }
                    lockButton("Zoom Lock",icon:"scope",enabled:model.settings.zoomLock,
                               disabledReason:zoomLockDisabledReason) { model.change{$0.zoomLock.toggle()} }
                    lockButton("Action",icon:"figure.run",enabled:model.settings.actionStabilization,
                               disabledReason:actionDisabledReason) { model.change{$0.actionStabilization.toggle()} }
                    lockButton("Smart",icon:"sparkles",enabled:model.settings.smartArtifactGuard,
                               disabledReason:smartDisabledReason) { model.change{$0.smartArtifactGuard.toggle()} }
                    nativeStabilizationControl
                }.padding(.horizontal,1)
            }
            ScrollView(.horizontal,showsIndicators:false) {
                LazyHStack(spacing:17) {
                    ForEach(CameraMode.visibleCases) { mode in
                        let reason=modeUnavailableReason(mode)
                        Button {
                            if let reason { model.notice=reason }
                            else { model.notice=nil; model.selectMode(mode) }
                        } label: {
                            Text(mode.rawValue).font(.system(size:10,weight:.semibold))
                                .foregroundStyle(mode == model.settings.mode ? .yellow:.white.opacity(reason == nil ? 0.72:0.28))
                        }
                        .buttonStyle(.plain).id(mode.id)
                    }
                }.padding(.horizontal,2)
            }
            .animation(nil,value:model.settings.mode)
            Text(model.notice ?? model.settings.mode.helpText)
                .font(.system(size:9,weight:model.notice == nil ? .regular:.semibold))
                .foregroundStyle(model.notice == nil ? Color.secondary:Color.orange)
                .lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                .onTapGesture { model.notice=nil }
            shutterRow
        }
    }

    private var quickControls: some View {
        VStack(spacing:5) {
            HStack(spacing:7) {
                quickToggle("AE/AF",icon:"viewfinder",on:model.settings.aeafLock) { model.change{$0.aeafLock.toggle()} }
                quickToggle("Lens",icon:"camera.aperture",on:model.settings.contentAwareDistortionCorrection,
                            disabled:!model.capabilities.contentAwareDistortionCorrection) { model.change{$0.contentAwareDistortionCorrection.toggle()} }
                quickToggle("Overview",icon:"rectangle.inset.filled",on:model.settings.showOverview) { model.change{$0.showOverview.toggle()} }
                quickToggle("Stats",icon:"waveform.path.ecg",on:model.settings.showStats) { model.change{$0.showStats.toggle()} }
            }
            HStack(spacing:7) {
                Image(systemName:"sun.min.fill").font(.caption2)
                Slider(value:model.binding(\\.exposureEV),in:model.capabilities.minEV...max(model.capabilities.minEV+0.1,model.capabilities.maxEV),step:0.1)
                    .disabled(model.settings.manualExposure || model.settings.aeafLock)
                Text(String(format:"%+.1f",model.settings.exposureEV)).font(.caption2.monospacedDigit()).frame(width:32)
            }
        }
        .padding(7).background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:9))
    }

    private var nativeStabilizationControl: some View {
        let blocked=nativeStabilizationDisabledReason != nil
        return HStack(spacing:0) {
            Button {
                if let reason=nativeStabilizationDisabledReason { model.notice=reason; return }
                model.notice=nil
                model.change { settings in
                    if settings.stabilization == .off { settings.stabilization = preferredNativeChoice }
                    else { settings.stabilization = .off }
                }
            } label: {
                HStack(spacing:4) {
                    Image(systemName:model.settings.stabilization == .off ? "square":"checkmark.square.fill")
                    VStack(alignment:.leading,spacing:0) {
                        Text("Native").font(.system(size:10,weight:.medium))
                        Text(model.settings.stabilization == .off ? "Off":model.settings.stabilization.rawValue)
                            .font(.system(size:7)).lineLimit(1)
                    }
                }.padding(.leading,7).padding(.vertical,6)
            }
            Menu {
                Button("Off") { model.change{$0.stabilization = .off} }
                ForEach(model.capabilities.supportedStabilizationModes.filter{$0 != .off && $0 != .auto}) { choice in
                    Button(choice.rawValue) { model.change{$0.stabilization = choice} }
                }
            } label: { Image(systemName:"chevron.down").font(.system(size:8,weight:.bold)).frame(width:22,height:34) }
            .disabled(blocked || !model.canConfigure)
        }
        .frame(width:112)
        .foregroundStyle(model.settings.stabilization != .off ? Color.yellow:Color.white.opacity(blocked ? 0.3:1))
        .background(model.settings.stabilization != .off ? Color.yellow.opacity(0.10):Color.white.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
    }

    private var shutterRow:''', re.S)

# Smaller shutter to return viewfinder area.
rep('App/CameraView.swift',
    '                Circle().stroke(.white,lineWidth:3).frame(width:70,height:70)\n',
    '                Circle().stroke(.white,lineWidth:3).frame(width:60,height:60)\n')
rep('App/CameraView.swift',
    '                    RoundedRectangle(cornerRadius:5).fill(.red).frame(width:28,height:28)\n',
    '                    RoundedRectangle(cornerRadius:5).fill(.red).frame(width:24,height:24)\n')
rep('App/CameraView.swift',
    '                    Circle().fill(model.settings.mode.isMovie ? Color.red:Color.white).frame(width:59,height:59)\n',
    '                    Circle().fill(model.settings.mode.isMovie ? Color.red:Color.white).frame(width:50,height:50)\n')

# Lock buttons are tappable while gray so they can explain why, instead of dead controls.
sub1('App/CameraView.swift',
     r'    private func lockButton\(_ title:String,icon:String,enabled:Bool,disabled:Bool,action:@escaping\(\)->Void\) -> some View \{.*?\n    \}\n\n    private func framingAvailable',
     '''    private func lockButton(_ title:String,icon:String,enabled:Bool,disabledReason:String?,action:@escaping()->Void) -> some View {
        Button {
            guard model.canConfigure else { return }
            if let disabledReason { model.notice=disabledReason; return }
            model.notice=nil; action()
        } label: {
            HStack(spacing:4) { Image(systemName:enabled ? "checkmark.square.fill":"square"); Text(title).font(.system(size:10,weight:.medium)) }
                .frame(width:86).padding(.vertical,7)
                .foregroundStyle(enabled ? .yellow:.white.opacity(disabledReason == nil ? 1:0.3))
                .background(enabled ? Color.yellow.opacity(0.10):Color.white.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
        }
        .buttonStyle(.plain).accessibilityValue(enabled ? "On":"Off")
    }

    private func quickToggle(_ title:String,icon:String,on:Bool,disabled:Bool=false,action:@escaping()->Void) -> some View {
        Button(action:action) {
            VStack(spacing:2) { Image(systemName:icon); Text(title).font(.system(size:8,weight:.medium)) }
                .frame(maxWidth:.infinity).padding(.vertical,5)
                .foregroundStyle(on ? .yellow:.white.opacity(disabled ? 0.3:0.95))
                .background(on ? Color.yellow.opacity(0.10):Color.clear,in:RoundedRectangle(cornerRadius:7))
        }.disabled(disabled || !model.canConfigure)
    }

    private func framingAvailable''', re.S)

# Replace/extend availability helpers and labels.
sub1('App/CameraView.swift',
     r'    private func framingAvailable\(_ framing: Framing\) -> Bool \{.*?\n    private func handleDetectedCode',
     '''    private func framingAvailable(_ framing: Framing) -> Bool { framingUnavailableReason(framing) == nil }

    private var horizonDisabledReason: String? {
        if model.settings.mode.isStandaloneCaptureMode { return "Horizon Lock is unavailable in this standalone capture mode." }
        if model.settings.usesNativeMoviePipeline { return "This native movie format bypasses Horizon's custom crop/rotation path." }
        return nil
    }
    private var zoomLockDisabledReason: String? {
        if model.settings.mode.isStandaloneCaptureMode { return "Zoom Lock is unavailable in this standalone capture mode." }
        if model.settings.usesNativeMoviePipeline { return "This native movie format bypasses Horizon's frame-position crop path." }
        return nil
    }
    private var actionDisabledReason: String? {
        if model.settings.mode != .video { return "Action is available in Video mode." }
        if model.settings.fps > 60 { return "Action supports up to 60 fps; your selected frame rate stays unchanged." }
        if model.settings.usesNativeMoviePipeline { return "Action is unavailable with ProRes/Log/HDR, multichannel audio, or other native-only movie paths." }
        return nil
    }
    private var smartDisabledReason: String? {
        if model.settings.mode.isStandaloneCaptureMode { return "Smart stabilization is unavailable in this standalone capture mode." }
        if model.settings.usesNativeMoviePipeline { return "Smart custom correction is unavailable on this native-only movie path." }
        return nil
    }
    private var nativeStabilizationDisabledReason: String? {
        if !model.settings.mode.isMovie { return "Native stabilization applies to video modes." }
        if model.settings.horizonLock || model.settings.zoomLock { return "Native stabilization is paused while Horizon or Zoom Lock owns the crop." }
        if model.capabilities.supportedStabilizationModes.filter({$0 != .off && $0 != .auto}).isEmpty { return "This active camera format reports no native stabilization mode." }
        return nil
    }
    private var preferredNativeChoice: StabilizationChoice {
        let modes=model.capabilities.supportedStabilizationModes
        if modes.contains(.lowLatency) { return .lowLatency }
        if modes.contains(.standard) { return .standard }
        return modes.first(where:{$0 != .off && $0 != .auto}) ?? .off
    }

    private func modeUnavailableReason(_ mode:CameraMode) -> String? {
        switch mode {
        case .slowMotion: return model.capabilities.supportedSlowMotionFPS.isEmpty ? "Slo-mo is not supported by the active camera." : nil
        case .cinematic: return !model.capabilities.cinematic ? "Cinematic is not supported by the active camera/format." : nil
        case .portrait: return !model.capabilities.depthData ? "Portrait needs depth support from the active camera." : nil
        case .spatial: return !model.capabilities.spatialVideo ? "Spatial Video is unavailable on the active camera/format." : nil
        case .spatialPhoto: return !model.capabilities.spatialPhoto ? "Spatial Photo needs a supported rear multi-camera system." : nil
        case .dualCapture: return !model.capabilities.multiCam ? "Dual Capture needs MultiCam support on this iPhone." : nil
        default:return nil
        }
    }
    private func codecUnavailableReason(_ codec:CodecChoice) -> String? {
        if model.codecAvailable(codec) { return nil }
        if model.settings.actionStabilization && codec.isProRes { return "turn Action off" }
        if codec.isProRes { return "not supported by this camera/format" }
        if codec == .compatible && model.settings.colorProfile != .sdr { return "requires SDR" }
        return "not supported by this selection"
    }
    private func colorProfileUnavailableReason(_ profile:VideoColorProfile) -> String? {
        if model.colorProfileAvailable(profile) { return nil }
        if model.settings.actionStabilization && profile != .sdr { return "turn Action off" }
        return "not supported by this camera/codec"
    }
    private func resolutionUnavailableReason(_ resolution:Resolution) -> String? {
        if model.resolutionAvailable(resolution) { return nil }
        if model.settings.codec.isProResRAW { return resolution.isRAWFrameSize ? "not supported by this camera" : "RAW uses sensor frame sizes" }
        if resolution.isRAWFrameSize { return "requires ProRes RAW" }
        return model.isFrontCamera ? "not supported by the front camera" : "not supported by the active rear camera/format"
    }
    private func frameRateUnavailableReason(_ rate:Double) -> String? {
        if model.frameRateAvailable(rate) { return nil }
        if model.settings.actionStabilization && rate > 60 { return "Action supports up to 60 fps" }
        return model.isFrontCamera ? "not supported by the front camera at this size" : "not supported by this camera at this size"
    }
    private func framingUnavailableReason(_ framing:Framing) -> String? {
        if model.settings.mode.isStandaloneCaptureMode { return framing == model.settings.framing ? nil : "fixed by this capture mode" }
        if model.settings.mode.isMovie && model.settings.usesNativeMoviePipeline && framing != .portrait && framing != .landscape { return "native movie path supports 9:16 or 16:9" }
        return nil
    }
    private func resolutionLabel(_ resolution:Resolution) -> String {
        let size=resolution.exactSize ?? model.settings.framing.size(longEdge:resolution.longEdge)
        let mp=size.width*size.height/1_000_000
        return String(format:"%@ · %.1f MP",resolution.rawValue,mp)
    }

    private var rawAvailable: Bool {
        model.capabilities.raw && !model.settings.isProcessedPhoto && model.settings.mode == .photo && !model.settings.constantColor
    }
    private var livePhotoAvailable: Bool {
        model.capabilities.livePhoto && !model.settings.isProcessedPhoto && model.settings.mode == .photo && !model.settings.raw && !model.settings.constantColor
    }
    private var formatLabel: String {
        if model.settings.mode.isPhotoMode {
            let codec=model.settings.codec == .efficient ? "HEIF":"JPEG"
            let maxMP=model.capabilities.supportedPhotoResolutionsMP.max()
            let mp=model.settings.photoResolutionMP == 0 ? (maxMP.map{"MAX \\($0)MP"} ?? "MAX") : "\\(model.settings.photoResolutionMP)MP"
            return "\\(codec) \\(mp)"
        }
        let codec: String
        switch model.settings.codec {
        case .efficient: codec="HEVC"
        case .compatible: codec="H264"
        case .proResLT: codec="PR LT"
        case .proRes422: codec="PR 422"
        case .proResHQ: codec="PR HQ"
        case .proResRAW: codec="PR RAW"
        case .proResRAWHQ: codec="RAW HQ"
        }
        let output=model.settings.effectiveOutputResolution
        let res = output == model.settings.resolution ? resolutionLabel(output) : "\\(model.settings.resolution.rawValue)→\\(resolutionLabel(output))"
        return "\\(codec) · \\(res) · \\(FrameRateCatalog.label(model.settings.fps))"
    }
    private func modeUnavailable(_ mode:CameraMode) -> Bool { modeUnavailableReason(mode) != nil }
    private func handleDetectedCode''', re.S)

# Zoom rail shows focal length under zoom multiplier.
sub1('App/CameraView.swift',
     r'                HStack\(spacing:6\) \{\n                    Slider\(value:Binding\(get:\{log2\(max\(model\.displayZoom,0\.01\)\)\},set:\{model\.setDisplayZoom\(pow\(2,\$0\)\)\}\),in:lo\.\.\.hi\)\n                        \.tint\(\.white\.opacity\(0\.62\)\)\n                    Text\(String\(format:"%\.1f×",model\.displayZoom\)\)\.font\(\.caption2\.monospacedDigit\(\)\)\.frame\(width:38,alignment:\.trailing\)\n                \}',
     '''                HStack(spacing:6) {
                    Slider(value:Binding(get:{log2(max(model.displayZoom,0.01))},set:{model.setDisplayZoom(pow(2,$0))}),in:lo...hi)
                        .tint(.white.opacity(0.62))
                    VStack(alignment:.trailing,spacing:0) {
                        Text(String(format:"%.1f×",model.displayZoom)).font(.caption2.monospacedDigit())
                        Text("\\(model.displayFocalLengthMM) mm").font(.system(size:7,design:.monospaced)).foregroundStyle(.secondary)
                    }.frame(width:48,alignment:.trailing)
                }''')
rep('App/CameraView.swift', '.frame(height:26).padding(.top,3)', '.frame(height:30).padding(.top,3)')

# MARK: Settings sheet becomes advanced/rare controls, not the primary shooting UI.
# Remove the duplicated native picker / Action assist from Smart section.
sub1('App/CameraSettingsView.swift',
     r'            if model\.settings\.mode\.isMovie \{\n                Picker\("Native stabilization".*?\n            \}\n',
     '''            if model.settings.mode.isMovie {
                Text("Native stabilization is controlled from the main camera strip. Exposure compensation and AE/AF Lock are available in the camera controls tray.")
                    .font(.caption).foregroundStyle(.secondary)
            }
''', re.S)

rep('App/CameraSettingsView.swift',
    '        Section("Focus and exposure") {\n',
    '        Section("Advanced focus and exposure") {\n            Text("Basic exposure compensation and AE/AF Lock live on the camera screen. These are the advanced/manual controls.")\n                .font(.caption).foregroundStyle(.secondary)\n')

rep('App/CameraSettingsView.swift',
    '            Toggle("Mini full-lens overview", isOn:model.binding(\\.showOverview))\n',
    '            Toggle("Mini full-lens overview", isOn:model.binding(\\.showOverview))\n            Toggle("Statistics overlay", isOn:model.binding(\\.showStats))\n')
rep('App/CameraSettingsView.swift',
    '            Text("Live Text detects quietly; the text panel only opens after you tap the Live Text button. Mini overview is off by default and shows the full active lens with the actual output crop in yellow. Grid is off by default. Persistent settings are remembered; live zoom resets to 1× each launch.")\n',
    '            Text("Live Text appears automatically when text is detected; tap the chip to expand/copy it. Mini overview is on by default. Statistics and Grid are off by default. Persistent settings are remembered; live zoom resets to 1× each launch.")\n')
rep('App/CameraSettingsView.swift',
    '            Text("Custom metadata is off by default. With it off, HorizonCamera preserves camera/AVFoundation metadata instead of injecting title/author/software fields. Location is also off until explicitly enabled.")\n',
    '            Text("Custom title/author metadata is off by default. Location metadata is on by default and can be disabled here; HorizonCamera otherwise preserves camera/AVFoundation metadata.")\n')
rep('App/CameraSettingsView.swift',
    '            Text("Captures are retained in HorizonCamera\'s local library first. Photos permission is add-only; the app does not read your existing library or upload captures.")\n',
    '            Text("Captures are retained in HorizonCamera\'s local library first. Camera-library permission is requested at startup so Photos access is ready when you use library features; captures are never uploaded by HorizonCamera.")\n')

# MARK: Switch latency - cache inputs and retain the last preview until new-camera frames arrive.
rep('App/CaptureEngine.swift',
    '    private var videoInput: AVCaptureDeviceInput?\n',
    '    private var videoInput: AVCaptureDeviceInput?\n    private var inputCache: [String:AVCaptureDeviceInput] = [:]\n')
rep('App/CaptureEngine.swift',
    '        let input = try AVCaptureDeviceInput(device: device)\n',
    '        let input: AVCaptureDeviceInput\n        if let cached=inputCache[device.uniqueID] { input=cached }\n        else { let created=try AVCaptureDeviceInput(device:device); inputCache[device.uniqueID]=created; input=created }\n')
rep('App/ImagePipeline.swift',
    '    func resetGeometry() {\n',
    '    func resetGeometry(keepPreview: Bool = false) {\n')
rep('App/ImagePipeline.swift',
    '        preview.publish(nil); fpsCount = 0; fpsStart = 0; planHistory.removeAll(); frozenAngle = nil\n',
    '        if !keepPreview { preview.publish(nil) }; fpsCount = 0; fpsStart = 0; planHistory.removeAll(); frozenAngle = nil\n')
rep('App/ImagePipeline.swift',
    '        if geometryReset { resetGeometry() }\n',
    '        if geometryReset { resetGeometry(keepPreview:true) }\n')
rep('App/CaptureEngine.swift',
    '            if changedSource { processor.resetGeometry() }\n',
    '            if changedSource { processor.resetGeometry(keepPreview: previousDeviceID != nil && previousDeviceID != device.uniqueID) }\n')

# Publish the unaffected preview before rendering the heavier corrected recording frame.
rep('App/ImagePipeline.swift',
    '        let previewImage = renderer.applyLook(renderer.transform(source,plan:previewPlan),settings:settings)\n        let recordingImage = recording ? renderer.applyLook(renderer.transform(source,plan:capturePlan),settings:settings) : previewImage\n        let target = settings.zoomLock ? Point2(0.5,0.5) : nil\n',
    '        let previewImage = renderer.applyLook(renderer.transform(source,plan:previewPlan),settings:settings)\n        let target = settings.zoomLock ? Point2(0.5,0.5) : nil\n        if recording {\n            let early=PreviewFrame(image:previewImage,recordingImage:previewImage,overview:source,plan:previewPlan,recordingPlan:previewPlan,target:target,trackingGood:settings.zoomLock && !previewPlan.wasClamped,diagnostics:diagnostics)\n            preview.publish(early)\n        }\n        let recordingImage = recording ? renderer.applyLook(renderer.transform(source,plan:capturePlan),settings:settings) : previewImage\n')

# Sanity checks
view=Path('App/CameraView.swift').read_text()
assert 'info.circle' not in view
assert 'showStats' in view
assert 'displayFocalLengthMM' in view
assert 'Zoom Lock' in view and 'actionStabilization' in view
assert 'frame(width:60,height:60)' in view
settings=Path('App/CameraSettingsView.swift').read_text()
assert 'Statistics overlay' in settings
assert 'Mini overview is on by default' in settings
engine=Path('App/CaptureEngine.swift').read_text()
assert 'inputCache' in engine
print('camera UI patch prepared')
