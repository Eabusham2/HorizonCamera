import SwiftUI

struct CameraView: View {
    @ObservedObject var model: CameraModel
    @State private var showLiveTextPanel = false
    @State private var showQuickControls = false
    @State private var quickTakeTriggered = false

    var body: some View {
        VStack(spacing:0) {
            topBar.padding(.horizontal,12).padding(.vertical,7)
            viewfinder.frame(maxWidth:.infinity,maxHeight:.infinity)
            controls.padding(.horizontal,12).padding(.top,7).padding(.bottom,9)
        }
        .background(Color.black)
        .modifier(CameraHardwareCaptureModifier(model:model))
        .sheet(isPresented:$model.showSettings) { CameraSettingsView(model:model) }
        .fullScreenCover(isPresented:$model.showLibrary,onDismiss:{ Task { await model.start() } }) { MediaLibraryView(library:model.library) }
        .alert("Camera",isPresented:Binding(get:{model.error != nil},set:{if !$0 { model.error=nil }})) {
            if model.permissionDenied, let url=URL(string:UIApplication.openSettingsURLString) { Link("Open Settings",destination:url) }
            Button("OK",role:.cancel) { model.error=nil }
        } message: { Text(model.error ?? "") }
    }

    private var topBar: some View {
        HStack(spacing:15) {
            if model.settings.mode.isPhotoMode { flashControl } else { torchControl }
            if model.settings.mode.isPhotoMode { timerControl; livePhotoControl; rawControl }
            if model.settings.mode.isMovie { hdrControl }
            formatControl
            aspectControl
            Spacer(minLength:2)
            Button { model.settings.mode.isPhotoMode ? model.change{$0.grid.toggle()} : model.change{$0.showLevel.toggle()} } label: {
                Image(systemName:model.settings.mode.isPhotoMode ? "grid" : "level")
                    .foregroundStyle((model.settings.mode.isPhotoMode ? model.settings.grid:model.settings.showLevel) ? .yellow:.white)
            }
            Button { withAnimation(.easeInOut(duration:0.15)) { showQuickControls.toggle() } } label: {
                Image(systemName:showQuickControls ? "chevron.up.circle.fill":"chevron.down.circle")
            }
            .accessibilityLabel("Camera controls")
            Button { model.showSettings=true } label: { Image(systemName:"gearshape") }
                .disabled(model.isRecording || model.busy)
        }
        .font(.system(size:17,weight:.medium))
        .foregroundStyle(.white)
    }

    private var flashControl: some View {
        Menu {
            ForEach(FlashChoice.allCases) { flash in
                Button(flash.rawValue) { model.change { $0.flash=flash } }
                    .disabled(!model.capabilities.flash)
            }
        } label: { Image(systemName:model.settings.flash == .off ? "bolt.slash.fill":"bolt.fill") }
        .disabled(!model.canConfigure || !model.capabilities.flash)
    }
    private var torchControl: some View {
        Button { model.change{$0.torch.toggle()} } label: { Image(systemName:model.settings.torch ? "bolt.fill":"bolt.slash.fill") }
            .foregroundStyle(model.settings.torch ? .yellow:.white)
            .disabled(!model.canConfigure || !model.capabilities.torch)
    }
    private var timerControl: some View {
        Menu {
            ForEach([0,3,5,10],id:\.self) { seconds in
                Button(seconds == 0 ? "Timer Off":"\(seconds)s") { model.change{$0.timer=seconds} }
            }
        } label: {
            ZStack(alignment:.bottomTrailing) {
                Image(systemName:"timer")
                if model.settings.timer > 0 { Text("\(model.settings.timer)").font(.system(size:8,weight:.bold)).offset(x:5,y:4) }
            }
        }
    }
    private var livePhotoControl: some View {
        Button { model.change{$0.livePhoto.toggle()} } label: { Image(systemName:"livephoto") }
            .foregroundStyle(model.settings.livePhoto ? .yellow:.white)
            .disabled(!livePhotoAvailable)
            .opacity(livePhotoAvailable ? 1:0.35)
    }
    private var rawControl: some View {
        Menu {
            Button("Off") { model.change { $0.raw=false } }
            Button("Apple ProRAW") { model.change { $0.raw=true; $0.preferProRAW=true } }
                .disabled(!rawAvailable || !model.capabilities.proRAW)
            Button("Bayer RAW") { model.change { $0.raw=true; $0.preferProRAW=false } }
                .disabled(!rawAvailable || !model.capabilities.raw)
            Text("RAW options are gray while Horizon/Zoom/filter/processed-photo features require rendered output.")
        } label: {
            Text(model.settings.raw ? (model.settings.preferProRAW && model.capabilities.proRAW ? "RAW+":"RAW") : "RAW")
                .font(.system(size:11,weight:.bold)).foregroundStyle(model.settings.raw ? .yellow:.white)
        }
        .disabled(!rawAvailable)
        .opacity(rawAvailable ? 1:0.35)
    }
    private var hdrControl: some View {
        Menu {
            Section("Color") {
                ForEach(VideoColorProfile.allCases) { profile in
                    let reason=colorProfileUnavailableReason(profile)
                    Button(reason == nil ? profile.rawValue : "\(profile.rawValue) — \(reason!)") {
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
    private var formatControl: some View {
        Menu {
            Section("Codec") {
                ForEach(CodecChoice.allCases) { codec in
                    let reason=codecUnavailableReason(codec)
                    Button(reason == nil ? codec.rawValue : "\(codec.rawValue) — \(reason!)") {
                        if reason == nil { model.notice=nil; model.selectCodec(codec) }
                    }
                    .disabled(reason != nil)
                }
            }
            if model.settings.mode.isMovie {
                Section("Frame Size") {
                    ForEach(Resolution.allCases) { resolution in
                        let reason=resolutionUnavailableReason(resolution)
                        Button(reason == nil ? resolutionLabel(resolution) : "\(resolutionLabel(resolution)) — \(reason!)") {
                            if reason == nil { model.notice=nil; model.selectResolution(resolution) }
                        }
                        .disabled(reason != nil)
                    }
                }
                Section("Frame Rate") {
                    ForEach(FrameRateCatalog.all,id:\.self) { rate in
                        let reason=frameRateUnavailableReason(rate)
                        Button(reason == nil ? "\(FrameRateCatalog.label(rate)) fps" : "\(FrameRateCatalog.label(rate)) fps — \(reason!)") {
                            if reason == nil { model.notice=nil; model.selectFrameRate(rate) }
                        }
                        .disabled(reason != nil)
                    }
                }
            } else if !model.capabilities.supportedPhotoResolutionsMP.isEmpty {
                Section("Photo Resolution") {
                    Button("Maximum · \(model.capabilities.supportedPhotoResolutionsMP.max().map(String.init) ?? "?") MP") { model.change{$0.photoResolutionMP=0} }
                    ForEach(model.capabilities.supportedPhotoResolutionsMP,id:\.self) { mp in
                        Button("\(mp) MP") { model.change{$0.photoResolutionMP=mp} }
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
    private var aspectControl: some View {
        Menu {
            Section("Output Aspect") {
                ForEach(Framing.allCases) { framing in
                    let reason=framingUnavailableReason(framing)
                    Button(reason == nil ? framing.rawValue : "\(framing.rawValue) — \(reason!)") {
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

    private var viewfinder: some View {
        GeometryReader { geometry in
            let ratio=model.settings.framing.ratio
            let width=min(geometry.size.width,geometry.size.height*ratio)
            let height=width/ratio
            ZStack {
                if let feed=model.preview, let renderer=model.renderer {
                    MetalPreview(feed:feed,renderer:renderer,zoom:{model.displayZoom},tap:{model.tap($0)},
                                 pinch:{model.setDisplayZoom($0,at:$1)},hold:{model.change{$0.aeafLock.toggle()}})
                    if model.settings.grid { grid.allowsHitTesting(false) }
                    reticles(width:width,height:height).allowsHitTesting(false)
                    VStack(spacing:0) {
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:4) {
                                if model.settings.aeafLock { Text("AE/AF LOCK").font(.caption2.bold()).foregroundStyle(.yellow) }
                                if model.settings.showStats {
                                    VStack(alignment:.leading,spacing:1) {
                                        Text(String(format:"%.1f FPS",model.diagnostics.deliveredFPS))
                                        Text("DROP \(model.diagnostics.droppedFrames)")
                                        Text(model.diagnostics.trackingStatus.uppercased())
                                    }
                                    .font(.system(size:8,weight:.semibold,design:.monospaced))
                                    .padding(.horizontal,6).padding(.vertical,4)
                                    .background(.black.opacity(0.55),in:RoundedRectangle(cornerRadius:6))
                                }
                            }
                            Spacer()
                            if model.settings.showOverview {
                                OverviewView(feed:feed,renderer:renderer,keepLevel:model.settings.horizonLock)
                                    .frame(width:88,height:118).clipShape(RoundedRectangle(cornerRadius:9))
                                    .overlay(RoundedRectangle(cornerRadius:9).stroke(.white.opacity(0.45),lineWidth:0.8))
                            }
                        }
                        Spacer()
                        HStack(alignment:.bottom) {
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
                                .accessibilityLabel("Live Text: \(model.detectedText.first ?? "detected text")")
                            }
                        }
                        ZoomRail(model:model).frame(height:30).padding(.top,3)
                    }.padding(8)
                }
                if showLiveTextPanel && model.settings.showDetectedText && !model.detectedText.isEmpty {
                    VStack(spacing:8) {
                        Text(model.detectedText.prefix(6).joined(separator:"\n")).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("Copy") { UIPasteboard.general.string=model.detectedText.joined(separator:"\n") }
                            Button("Close") { showLiveTextPanel=false }
                        }.font(.caption.bold())
                    }
                    .padding(12).frame(maxWidth:min(300,width-30)).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                if let code=model.detectedCode {
                    VStack { Spacer(); Button { handleDetectedCode(code) } label: {
                        Label("QR",systemImage:"qrcode").font(.caption.bold()).padding(.horizontal,10).padding(.vertical,7).background(.ultraThinMaterial,in:Capsule())
                    }.buttonStyle(.plain).padding(.bottom,54) }
                }
                if model.state == .starting { ProgressView().tint(.white) }
                if model.state == .stopped {
                    VStack(spacing:10) {
                        Image(systemName:"camera.fill").font(.largeTitle)
                        Text(model.permissionDenied ? "Camera access is required":"Camera paused").font(.headline)
                        Button("Start") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                    }
                }
                if let count=model.countdown { Text("\(count)").font(.system(size:88,weight:.light)).shadow(radius:8) }
                if model.state == .finishing { ProgressView().tint(.white) }
            }
            .frame(width:width,height:height).clipped()
            .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }
    }

    private var grid: some View {
        Canvas { context,size in
            var p=Path()
            for n in 1...2 {
                let f=CGFloat(n)/3
                p.move(to:CGPoint(x:size.width*f,y:0)); p.addLine(to:CGPoint(x:size.width*f,y:size.height))
                p.move(to:CGPoint(x:0,y:size.height*f)); p.addLine(to:CGPoint(x:size.width,y:size.height*f))
            }
            context.stroke(p,with:.color(.white.opacity(0.18)),lineWidth:0.45)
        }
    }
    @ViewBuilder private func reticles(width:CGFloat,height:CGFloat) -> some View {
        if model.settings.zoomLock, let frame=model.preview?.snapshot(), let point=frame.target {
            RoundedRectangle(cornerRadius:5).stroke(frame.trackingGood ? Color.yellow:Color.orange,lineWidth:1.5)
                .frame(width:36,height:36).position(x:point.x*width,y:(1-point.y)*height)
        } else if let point=model.focusPoint {
            RoundedRectangle(cornerRadius:3).stroke(.yellow,lineWidth:1.4).frame(width:58,height:58).position(x:point.x*width,y:point.y*height)
        }
        if model.settings.showLevel {
            let roll=AngleMath.wrap(model.diagnostics.rollDegrees * .pi / 180) * 180 / .pi
            Rectangle().fill(abs(roll)<1 ? Color.yellow:Color.white.opacity(0.55))
                .frame(width:38,height:1).rotationEffect(.degrees(model.settings.horizonLock ? 0:roll)).position(x:width/2,y:height/2)
        }
    }

    private var controls: some View {
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
                Slider(value:model.binding(\.exposureEV),in:model.capabilities.minEV...max(model.capabilities.minEV+0.1,model.capabilities.maxEV),step:0.1)
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

    private var shutterRow: some View {
        HStack {
            Group {
                if model.isRecording && model.settings.mode != .dualCapture {
                    Button { model.captureStillWhileRecording() } label: {
                        Circle().fill(.white).frame(width:38,height:38).overlay(Circle().stroke(.black.opacity(0.25),lineWidth:1))
                    }.accessibilityLabel("Take still photo while recording")
                } else {
                    Button { model.openLibrary() } label: { LibraryThumbnail(library:model.library).frame(width:42,height:42).clipShape(RoundedRectangle(cornerRadius:9)) }
                        .disabled(model.busy || model.countdown != nil)
                }
            }.frame(width:64)
            Spacer()
            shutterButton
            Spacer()
            HStack(spacing:6) {
                if model.settings.mode == .photo && !model.isRecording {
                    Button { model.toggleBurstLock() } label: {
                        Image(systemName:model.burstLocked ? "lock.fill":"square.stack.3d.up.fill").font(.system(size:18)).frame(width:32,height:38)
                    }.foregroundStyle(model.burstLocked ? .yellow:.white).accessibilityLabel("Burst lock")
                }
                if model.isRecording && model.settings.mode == .photo {
                    Button { model.lockQuickTake() } label: {
                        Image(systemName:model.quickTakeLocked ? "lock.fill":"lock.open").font(.system(size:18)).frame(width:32,height:38)
                    }.foregroundStyle(model.quickTakeLocked ? .yellow:.white).accessibilityLabel("Lock QuickTake recording")
                }
                Button { model.flipCamera() } label: { Image(systemName:"arrow.triangle.2.circlepath.camera").font(.system(size:22)).frame(width:36,height:38) }
                    .disabled(!model.canConfigure && !model.isRecording)
            }.frame(width:72)
        }.foregroundStyle(.white)
    }

    private var shutterButton: some View {
        Button(action:{
            if quickTakeTriggered { quickTakeTriggered=false; return }
            model.shutter()
        }) {
            ZStack {
                Circle().stroke(.white,lineWidth:3).frame(width:60,height:60)
                if model.isRecording {
                    RoundedRectangle(cornerRadius:5).fill(.red).frame(width:24,height:24)
                } else {
                    Circle().fill(model.settings.mode.isMovie ? Color.red:Color.white).frame(width:50,height:50)
                    if model.busy { ProgressView().tint(.black) }
                }
            }
        }
        .disabled(model.busy || model.state == .stopped)
        .onLongPressGesture(minimumDuration:0.35,maximumDistance:55,pressing:{ pressed in
            if !pressed && quickTakeTriggered {
                if !model.quickTakeLocked { model.stopQuickTake() }
                DispatchQueue.main.async { quickTakeTriggered=false }
            }
        },perform:{
            guard model.settings.mode == .photo && !model.isRecording && model.canConfigure else { return }
            quickTakeTriggered=true; model.startQuickTake()
        })
        .accessibilityLabel(model.isRecording ? "Stop recording":(model.settings.mode.isMovie ? "Start recording":"Take photo"))
    }

    private func lockButton(_ title:String,icon:String,enabled:Bool,disabledReason:String?,action:@escaping()->Void) -> some View {
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

    private func framingAvailable(_ framing: Framing) -> Bool { framingUnavailableReason(framing) == nil }

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
            let mp=model.settings.photoResolutionMP == 0 ? (maxMP.map{"MAX \($0)MP"} ?? "MAX") : "\(model.settings.photoResolutionMP)MP"
            return "\(codec) \(mp)"
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
        let res = output == model.settings.resolution ? resolutionLabel(output) : "\(model.settings.resolution.rawValue)→\(resolutionLabel(output))"
        return "\(codec) · \(res) · \(FrameRateCatalog.label(model.settings.fps))"
    }
    private func modeUnavailable(_ mode:CameraMode) -> Bool { modeUnavailableReason(mode) != nil }
    private func handleDetectedCode(_ value:String) {
        if let url=URL(string:value), let scheme=url.scheme?.lowercased(), ["http","https"].contains(scheme) { UIApplication.shared.open(url) }
        else { UIPasteboard.general.string=value }
    }
}

private struct ZoomRail: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        GeometryReader { geometry in
            let lo=log2(max(0.01,model.zoomRange.lowerBound)), hi=log2(max(model.zoomRange.upperBound,model.zoomRange.lowerBound+0.01))
            ZStack {
                ForEach(model.zoomDots,id:\.self) { dot in
                    let f=(log2(max(dot,0.01))-lo)/max(0.001,hi-lo)
                    Circle().fill(abs(model.displayZoom-dot)<0.07 ? Color.yellow:Color.white.opacity(0.72))
                        .frame(width:4,height:4).position(x:6+CGFloat(f)*max(1,geometry.size.width-56),y:geometry.size.height/2)
                }
                HStack(spacing:6) {
                    Slider(value:Binding(get:{log2(max(model.displayZoom,0.01))},set:{model.setDisplayZoom(pow(2,$0))}),in:lo...hi)
                        .tint(.white.opacity(0.62))
                    VStack(alignment:.trailing,spacing:0) {
                        Text(String(format:"%.1f×",model.displayZoom)).font(.caption2.monospacedDigit())
                        Text("\(model.displayFocalLengthMM) mm").font(.system(size:7,design:.monospaced)).foregroundStyle(.secondary)
                    }.frame(width:48,alignment:.trailing)
                }
            }
        }
        .background(Color.clear)
    }
}

private struct CameraHardwareCaptureModifier: ViewModifier {
    @ObservedObject var model: CameraModel
    @ViewBuilder func body(content:Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled:model.state != .stopped && !model.showLibrary) { event in
                if event.phase == .ended { model.shutter() }
            }
        } else { content }
    }
}

struct OverviewGeometry {
    static func imageRect(source: Size2, in size: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let ratio = source.width/source.height
        let width = min(size.width,size.height*ratio), height = width/ratio
        return CGRect(x:(size.width-width)/2,y:(size.height-height)/2,width:width,height:height)
    }
    static func capturePoints(plan: CropPlan, in size: CGSize, keepLevel: Bool = false) -> [CGPoint] {
        let rect=imageRect(source:plan.source,in:size)
        if keepLevel {
            let detail=plan.sourceDetail
            let center=CGPoint(x:rect.minX+plan.center.x/plan.source.width*rect.width,
                               y:rect.minY+(1-plan.center.y/plan.source.height)*rect.height)
            let width=detail.width/plan.source.width*rect.width
            let height=detail.height/plan.source.height*rect.height
            return [CGPoint(x:center.x-width/2,y:center.y-height/2),
                    CGPoint(x:center.x+width/2,y:center.y-height/2),
                    CGPoint(x:center.x+width/2,y:center.y+height/2),
                    CGPoint(x:center.x-width/2,y:center.y+height/2)]
        }
        let corners=[Point2(0,0),Point2(plan.output.width,0),Point2(plan.output.width,plan.output.height),Point2(0,plan.output.height)]
        return corners.map { corner in
            let q=plan.outputToSource(corner)
            return CGPoint(x:rect.minX+q.x/plan.source.width*rect.width,
                           y:rect.minY+(1-q.y/plan.source.height)*rect.height)
        }
    }
}

struct OverviewView: View {
    let feed: PreviewFeed
    let renderer: ImageRenderer
    let keepLevel: Bool
    var body: some View {
        ZStack {
            MetalPreview(feed:feed,renderer:renderer,overview:true)
            Canvas { context,size in
                guard let frame=feed.snapshot() else { return }
                let points=OverviewGeometry.capturePoints(plan:frame.plan,in:size,keepLevel:keepLevel)
                guard let first=points.first else { return }
                var path=Path(); path.move(to:first)
                for point in points.dropFirst() { path.addLine(to:point) }
                path.closeSubpath()
                context.stroke(path,with:.color(.yellow),lineWidth:1.5)
            }
        }.allowsHitTesting(false)
    }
}
