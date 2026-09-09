import SwiftUI

struct CameraView: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        VStack(spacing:0) {
            topBar.padding(.horizontal,20).padding(.vertical,10)
            viewfinder.frame(maxWidth:.infinity,maxHeight:.infinity)
            controls.padding(.horizontal,20).padding(.top,10).padding(.bottom,12)
        }
        .background(Color.black)
        .modifier(CameraHardwareCaptureModifier(model:model))
        .sheet(isPresented:$model.showSettings) { CameraSettingsView(model:model) }
        .fullScreenCover(isPresented:$model.showLibrary,onDismiss:{ Task { await model.start() } }) { MediaLibraryView(library:model.library) }
        .alert("Camera",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) {
            if model.permissionDenied, let url = URL(string:UIApplication.openSettingsURLString) {
                Link("Open Settings",destination:url)
            }
            Button("OK",role:.cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment:.top) {
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption)
                    Button { model.notice = nil } label: { Image(systemName:"xmark.circle.fill") }
                }.padding(12).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:14))
                    .padding(.horizontal,12).padding(.top,50)
            }
        }
    }
    private var topBar: some View {
        HStack {
            if model.settings.mode.isPhotoMode {
                Menu {
                    ForEach(FlashChoice.allCases) { flash in Button(flash.rawValue) { model.change { $0.flash = flash } } }
                } label: { Image(systemName:model.settings.flash == .off ? "bolt.slash.fill":"bolt.fill") }
                    .disabled(!model.canConfigure || !model.capabilities.flash)
            } else {
                Button { model.change { $0.torch.toggle() } } label: { Image(systemName:model.settings.torch ? "bolt.fill":"bolt.slash.fill") }
                    .foregroundStyle(model.settings.torch ? .yellow:.white)
                    .disabled(!model.canConfigure || !model.capabilities.torch)
            }
            Spacer()
            if model.isRecording {
                HStack(spacing:6) {
                    Circle().fill(.red).frame(width:8,height:8)
                    Text(time(model.diagnostics.recordingSeconds)).monospacedDigit().font(.system(.headline,design:.rounded))
                }.accessibilityLabel("Recording, \(time(model.diagnostics.recordingSeconds))")
            } else {
                Text("HORIZON").font(.system(size:14,weight:.semibold,design:.rounded)).tracking(3)
            }
            Spacer()
            Button { model.showSettings = true } label: { Image(systemName:"slider.horizontal.3") }
                .disabled(model.isRecording || model.busy)
        }.font(.system(size:20)).foregroundStyle(.white)
    }
    private var viewfinder: some View {
        GeometryReader { geometry in
            let ratio = model.settings.framing.ratio
            let width = min(geometry.size.width,geometry.size.height*ratio)
            let height = width/ratio
            ZStack {
                if let feed = model.preview, let renderer = model.renderer {
                    MetalPreview(feed:feed,renderer:renderer,zoom:{ model.settings.zoom },tap:{ model.tap($0) },
                                 pinch:{ model.zoom($0,at:$1) },hold:{ model.change { $0.aeafLock.toggle() } })
                    if model.settings.grid { grid.allowsHitTesting(false) }
                    reticles(width:width,height:height).allowsHitTesting(false)
                    VStack {
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:4) {
                                if model.settings.horizonLock { statusPill(model.diagnostics.motionStatus,icon:"gyroscope") }
                                if model.settings.zoomLock { statusPill(model.diagnostics.trackingStatus,icon:"scope") }
                                if model.settings.aeafLock { Text("AE/AF LOCK").font(.caption2.bold()).foregroundStyle(.yellow) }
                            }
                            Spacer(minLength:4)
                            if model.settings.zoomLock && model.settings.showOverview {
                                OverviewView(feed:feed,renderer:renderer)
                                    .frame(width:70,height:124).clipShape(RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.7),lineWidth:1))
                            }
                        }
                        Spacer()
                        HStack {
                            if model.diagnostics.upscaled { Text("UPSCALED OUTPUT").font(.system(size:9,weight:.semibold)).padding(5).background(.black.opacity(0.55),in:Capsule()) }
                            Spacer()
                            if !model.settings.audio && model.settings.mode == .video { Image(systemName:"mic.slash.fill").font(.caption) }
                        }
                    }.padding(10).allowsHitTesting(false)
                }
                if let code = model.detectedCode {
                    VStack {
                        Spacer()
                        Button { handleDetectedCode(code) } label: {
                            Label(code,systemImage:"qrcode")
                                .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                .padding(.horizontal,10).padding(.vertical,8)
                                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10))
                        }.buttonStyle(.plain).padding(.horizontal,12).padding(.bottom,54)
                    }
                }
                if model.settings.showDetectedText && !model.detectedText.isEmpty {
                    VStack {
                        Spacer()
                        HStack(alignment:.bottom) {
                            Text(model.detectedText.prefix(3).joined(separator:"\n"))
                                .font(.caption2).lineLimit(4).padding(8)
                                .background(.black.opacity(0.62),in:RoundedRectangle(cornerRadius:8))
                            Button { UIPasteboard.general.string = model.detectedText.joined(separator:"\n") } label: {
                                Image(systemName:"doc.on.doc").padding(8).background(.black.opacity(0.62),in:Circle())
                            }.accessibilityLabel("Copy detected text")
                        }.padding(.horizontal,12).padding(.bottom,10)
                    }
                }
                if model.state == .starting { ProgressView("Starting camera…").padding().background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:12)) }
                if model.state == .stopped {
                    VStack(spacing:12) {
                        Image(systemName:"camera.fill").font(.largeTitle)
                        Text(model.permissionDenied ? "Camera access is required":"Camera paused").font(.headline)
                        Button("Start camera") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                    }
                }
                if let count = model.countdown { Text("\(count)").font(.system(size:96,weight:.light)).shadow(radius:10) }
                if model.state == .finishing { ProgressView("Saving recording…").padding().background(.black.opacity(0.7),in:Capsule()) }
            }
            .frame(width:width,height:height).clipped()
            .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }
    }
    private var grid: some View {
        Canvas { context,size in
            var p = Path()
            for n in 1...2 {
                let f = CGFloat(n)/3
                p.move(to:CGPoint(x:size.width*f,y:0));p.addLine(to:CGPoint(x:size.width*f,y:size.height))
                p.move(to:CGPoint(x:0,y:size.height*f));p.addLine(to:CGPoint(x:size.width,y:size.height*f))
            }
            context.stroke(p,with:.color(.white.opacity(0.25)),lineWidth:0.5)
        }
    }
    @ViewBuilder private func reticles(width:CGFloat,height:CGFloat) -> some View {
        if let frame = model.preview?.snapshot(), let point = frame.target, model.settings.zoomLock {
            RoundedRectangle(cornerRadius:5).stroke(frame.trackingGood ? Color.green:Color.orange,lineWidth:2)
                .frame(width:42,height:42).position(x:point.x*width,y:(1-point.y)*height)
        } else if let point = model.focusPoint {
            RoundedRectangle(cornerRadius:3).stroke(.yellow,lineWidth:1.5)
                .frame(width:62,height:62).position(x:point.x*width,y:point.y*height)
        }
        if model.settings.showLevel {
            let roll = AngleMath.wrap(model.diagnostics.rollDegrees * .pi/180)*180 / .pi
            Rectangle().fill(abs(roll) < 1 ? Color.yellow:Color.white.opacity(0.6))
                .frame(width:44,height:1).rotationEffect(.degrees(model.settings.horizonLock ? 0:roll))
                .position(x:width/2,y:height/2)
        }
    }
    private var controls: some View {
        VStack(spacing:12) {
            HStack(spacing:10) {
                ForEach(model.capabilities.lenses.filter { !$0.isFront }) { lens in
                    Button { model.selectLens(lens) } label: {
                        Text(lens.label).font(.system(size:13,weight:.semibold)).frame(minWidth:37,minHeight:32)
                            .foregroundStyle(lens.id == model.capabilities.selectedLens ? .yellow:.white)
                            .background(.white.opacity(lens.id == model.capabilities.selectedLens ? 0.20:0.08),in:Capsule())
                    }.disabled(!model.canConfigure)
                }
                Spacer(minLength:4)
                Text(String(format:"%.1f× digital",model.settings.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value:Binding(get:{ model.settings.zoom },set:{ model.zoom($0) }),in:1...12)
                .tint(.yellow).disabled(model.busy || model.state == .stopped)
                .accessibilityLabel("Digital zoom")
            HStack(spacing:10) {
                lockButton("Horizon Lock",enabled:model.settings.horizonLock) { model.change { $0.horizonLock.toggle() } }
                lockButton("Zoom Lock",enabled:model.settings.zoomLock) { model.change { $0.zoomLock.toggle() } }
            }
            ScrollView(.horizontal, showsIndicators:false) {
                HStack(spacing:19) {
                    ForEach(CameraMode.allCases) { mode in
                        Button { model.selectMode(mode) } label: {
                            Text(mode.rawValue).font(.system(size:11,weight:.semibold))
                                .foregroundStyle(mode == model.settings.mode ? .yellow:.white.opacity(0.75))
                        }.disabled(!model.canConfigure || modeUnavailable(mode))
                    }
                }.padding(.horizontal,2)
            }.padding(.top,3)
            HStack {
                Button { model.openLibrary() } label: { LibraryThumbnail(library:model.library).frame(width:46,height:46).clipShape(RoundedRectangle(cornerRadius:10)) }
                    .disabled(model.isRecording || model.busy || model.countdown != nil)
                    .accessibilityLabel("Captured photos and videos")
                Spacer()
                Button { model.shutter() } label: {
                    ZStack {
                        Circle().stroke(.white,lineWidth:3).frame(width:76,height:76)
                        if model.isRecording {
                            RoundedRectangle(cornerRadius:5).fill(.red).frame(width:31,height:31)
                        } else {
                            Circle().fill(model.settings.mode.isMovie ? Color.red:Color.white).frame(width:64,height:64)
                            if model.busy { ProgressView().tint(.black) }
                            if model.countdown != nil { Image(systemName:"xmark").foregroundStyle(.black) }
                        }
                    }
                }.disabled(model.busy || model.state == .stopped)
                    .accessibilityLabel(model.isRecording ? "Stop recording":(model.settings.mode.isMovie ? "Start recording":"Take photo"))
                Spacer()
                Button { model.flipCamera() } label: { Image(systemName:"arrow.triangle.2.circlepath.camera").font(.system(size:25)).frame(width:46,height:46) }
                    .disabled(!model.canConfigure).accessibilityLabel("Switch front and back camera")
            }.foregroundStyle(.white)
        }
    }
    private func lockButton(_ title:String,enabled:Bool,action:@escaping ()->Void) -> some View {
        Button(action:action) {
            HStack(spacing:7) {
                Image(systemName:enabled ? "checkmark.square.fill":"square")
                Text(title).font(.system(size:13,weight:.medium))
            }.frame(maxWidth:.infinity).padding(.vertical,10)
                .foregroundStyle(enabled ? .yellow:.white)
                .background(enabled ? Color.yellow.opacity(0.13):Color.white.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
        }.disabled(!model.canConfigure || model.settings.usesNativeMoviePipeline || model.settings.mode == .portrait || model.settings.mode.isStandaloneCaptureMode || model.settings.mode == .action)
            .accessibilityValue(enabled ? "On":"Off")
    }
    private func statusPill(_ text:String,icon:String) -> some View {
        Label(text,systemImage:icon).font(.system(size:9,weight:.medium))
            .padding(.horizontal,7).padding(.vertical,5).background(.black.opacity(0.6),in:Capsule())
    }
    private func modeUnavailable(_ mode: CameraMode) -> Bool {
        switch mode {
        case .slowMotion: return model.capabilities.supportedSlowMotionFPS.isEmpty
        case .cinematic: return !model.capabilities.cinematic
        case .portrait: return !model.capabilities.depthData
        case .spatial: return !model.capabilities.spatialVideo
        case .spatialPhoto: return !model.capabilities.spatialPhoto
        case .dualCapture: return !model.capabilities.multiCam
        default: return false
        }
    }
    private func handleDetectedCode(_ value: String) {
        if let url = URL(string:value), let scheme = url.scheme?.lowercased(), ["http","https"].contains(scheme) {
            UIApplication.shared.open(url)
        } else { UIPasteboard.general.string = value }
    }
    private func time(_ seconds:Double) -> String {
        let s = max(0,Int(seconds)); return String(format:"%02d:%02d:%02d",s/3600,(s%3600)/60,s%60)
    }
}

private struct CameraHardwareCaptureModifier: ViewModifier {
    @ObservedObject var model: CameraModel
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled:model.state != .stopped && !model.showLibrary) { event in
                if event.phase == .ended { model.shutter() }
            }
        } else { content }
    }
}

struct OverviewView: View {
    let feed: PreviewFeed
    let renderer: ImageRenderer
    var body: some View {
        ZStack {
            MetalPreview(feed:feed,renderer:renderer,overview:true)
            Canvas { context,size in
                guard let frame = feed.snapshot() else { return }
                let p = frame.plan, ratio = p.source.width/p.source.height
                let w = min(size.width,size.height*ratio),h = w/ratio
                let origin = CGPoint(x:(size.width-w)/2,y:(size.height-h)/2)
                let corners = [Point2(0,0),Point2(p.output.width,0),Point2(p.output.width,p.output.height),Point2(0,p.output.height)]
                var path = Path()
                for (i,corner) in corners.enumerated() {
                    let q = p.outputToSource(corner)
                    let mapped = CGPoint(x:origin.x+q.x/p.source.width*w,y:origin.y+(1-q.y/p.source.height)*h)
                    if i == 0 { path.move(to:mapped) } else { path.addLine(to:mapped) }
                }
                path.closeSubpath()
                context.stroke(path,with:.color(frame.trackingGood ? .yellow:.orange),lineWidth:1.5)
            }
        }.allowsHitTesting(false)
    }
}
