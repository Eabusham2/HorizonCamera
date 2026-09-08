import SwiftUI
import AVKit
import PhotosUI
import ImageIO

private enum ThumbnailLoader {
    static let cache = NSCache<NSString,UIImage>()
    static func load(_ url:URL,video:Bool,maxSize:Int = 600) async -> UIImage? {
        let key = (url.absoluteString + "#" + String(maxSize)) as NSString
        if let image = cache.object(forKey:key) { return image }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.utility).async {
                var image: UIImage?
                if video {
                    let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width:maxSize,height:maxSize)
                    if let cg = try? generator.copyCGImage(at:.zero,actualTime:nil) { image = UIImage(cgImage:cg) }
                } else if let source = CGImageSourceCreateWithURL(url as CFURL,nil) {
                    let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxSize]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) { image = UIImage(cgImage:cg) }
                }
                if let image { cache.setObject(image,forKey:key,cost:maxSize*maxSize*4);cache.totalCostLimit = 40_000_000 }
                continuation.resume(returning:image)
            }
        }
    }
}
struct MediaThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.1)
                if let image { Image(uiImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped() }
                else { Image(systemName:item.isVideo ? "video.fill":"photo").foregroundStyle(.secondary) }
            }
        }.task(id:item.id) { image = await ThumbnailLoader.load(item.url,video:item.isVideo) }
    }
}
struct LibraryThumbnail: View {
    @ObservedObject var library: MediaLibrary
    var body: some View {
        if let item = library.items.first { MediaThumbnail(item:item) }
        else { ZStack { Color.white.opacity(0.1);Image(systemName:"photo.on.rectangle").foregroundStyle(.white) } }
    }
}
struct MediaLibraryView: View {
    @ObservedObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MediaItem?
    var body: some View {
        NavigationStack {
            ScrollView {
                if library.items.isEmpty {
                    ContentUnavailableView("Your captures appear here",systemImage:"photo.on.rectangle.angled",description:Text("Photos and recordings are kept locally, even without Photos permission."))
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:110),spacing:3)],spacing:3) {
                    ForEach(library.items) { item in
                        Button { selected = item } label: {
                            MediaThumbnail(item:item).aspectRatio(1,contentMode:.fit)
                                .overlay(alignment:.bottomLeading) {
                                    HStack(spacing:4) {
                                        if item.isVideo { Image(systemName:"video.fill") }
                                        if item.liveFilename != nil { Text("LIVE") }
                                        if item.rawFilename != nil { Text("RAW") }
                                    }.font(.system(size:10,weight:.bold)).foregroundStyle(.white)
                                        .padding(6).background(.black.opacity(0.35))
                                }
                        }.buttonStyle(.plain)
                    }
                }.padding(3)
            }
            .navigationTitle("Captures")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Camera") { dismiss() } } }
            .sheet(item:$selected) { item in MediaDetailView(item:item,library:library) }
            .safeAreaInset(edge:.bottom) {
                if let text = library.message { Text(text).font(.caption).padding(10).frame(maxWidth:.infinity).background(.ultraThinMaterial) }
            }
        }.tint(.yellow)
    }
}
struct MediaDetailView: View {
    let item: MediaItem
    @ObservedObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var delete = false
    @State private var scale = 1.0
    @State private var baseScale = 1.0
    var body: some View {
        NavigationStack {
            VStack(spacing:12) {
                ZStack {
                    Color.black
                    if item.isVideo {
                        if let player { VideoPlayer(player:player) }
                    } else {
                        if let image { Image(uiImage:image).resizable().scaledToFit().scaleEffect(scale) }
                        if let movie = item.liveURL { LocalLivePhotoView(photo:item.url,movie:movie) }
                    }
                }.clipped()
                    .gesture(MagnifyGesture().onChanged { scale = min(max(baseScale*$0.magnification,1),6) }.onEnded { _ in baseScale = scale })
                    .onTapGesture(count:2) { scale = 1;baseScale = 1 }
                Text(item.summary).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Text(item.created,style:.date).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing:24) {
                    ShareLink(item:item.url) { Label("Share",systemImage:"square.and.arrow.up") }
                    Menu {
                        Button("Save to Photos") { Task { await library.exportToPhotos(item) } }
                        if let raw = item.rawURL { ShareLink("Share DNG",item:raw) }
                        if let live = item.liveURL { ShareLink("Share Live Photo movie",item:live) }
                        Button("Delete local copy",role:.destructive) { delete = true }
                    } label: { Label("More",systemImage:"ellipsis.circle") }
                }.padding(.bottom,20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete the app's copy? This does not delete anything in Apple Photos.",isPresented:$delete,titleVisibility:.visible) {
                Button("Delete local copy",role:.destructive) { library.deleteLocal(item);dismiss() }
            }
            .task {
                if item.isVideo {
                    try? AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback)
                    player = AVPlayer(url:item.url)
                } else { image = await ThumbnailLoader.load(item.url,video:false,maxSize:2400) }
            }
            .onDisappear { player?.pause();player = nil }
        }.tint(.yellow)
    }
}
struct LocalLivePhotoView: UIViewRepresentable {
    let photo: URL
    let movie: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context:Context) -> PHLivePhotoView {
        let view = PHLivePhotoView();view.contentMode = .scaleAspectFit
        context.coordinator.request = PHLivePhoto.request(withResourceFileURLs:[photo,movie],placeholderImage:nil,
            targetSize:CGSize(width:1200,height:1200),contentMode:.aspectFit) { [weak view] live,_ in
                DispatchQueue.main.async { view?.livePhoto = live }
            }
        return view
    }
    func updateUIView(_ uiView:PHLivePhotoView,context:Context) {}
    static func dismantleUIView(_ uiView:PHLivePhotoView,coordinator:Coordinator) {
        if let id = coordinator.request { PHLivePhoto.cancelRequest(withRequestID:id) }
    }
    final class Coordinator { var request: PHLivePhotoRequestID? }
}
