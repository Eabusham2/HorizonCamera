import Foundation
import Photos
import Combine

struct MediaDraft {
    let url: URL
    var liveMovie: URL? = nil
    var raw: URL? = nil
    var isVideo = false
    var summary = ""
}
struct MediaItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var created = Date()
    let filename: String
    var liveFilename: String?
    var rawFilename: String?
    let isVideo: Bool
    var summary: String
    var savedToPhotos = false
    var url: URL { MediaFiles.directory.appendingPathComponent(filename) }
    var liveURL: URL? { liveFilename.map { MediaFiles.directory.appendingPathComponent($0) } }
    var rawURL: URL? { rawFilename.map { MediaFiles.directory.appendingPathComponent($0) } }
}
enum MediaFiles {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }
    static func newURL(extension suffix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }
    static func requireSpace() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes < 250_000_000 {
            throw CameraFailure.message("Less than 250 MB is available. Free storage before capturing.")
        }
    }
}
@MainActor final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var message: String?
    private var manifest: URL { MediaFiles.directory.appendingPathComponent("library.json") }
    init() {
        do {
            try FileManager.default.createDirectory(at: MediaFiles.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: manifest))
                items = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            }
            // Recover any capture whose app was interrupted before the manifest write.
            let known = Set(items.flatMap { [$0.filename, $0.liveFilename, $0.rawFilename].compactMap { $0 } })
            let disk = try FileManager.default.contentsOfDirectory(at: MediaFiles.directory, includingPropertiesForKeys: nil)
            for url in disk where !known.contains(url.lastPathComponent) && ["mov","heic","jpg","dng"].contains(url.pathExtension.lowercased()) {
                items.append(MediaItem(filename: url.lastPathComponent, isVideo: url.pathExtension == "mov", summary: "Recovered local capture"))
            }
            items.sort { $0.created > $1.created }
        } catch { message = "Local library: \(error.localizedDescription)" }
    }
    func add(_ draft: MediaDraft, saveToPhotos: Bool) async {
        let item = MediaItem(filename: draft.url.lastPathComponent, liveFilename: draft.liveMovie?.lastPathComponent,
                             rawFilename: draft.raw?.lastPathComponent, isVideo: draft.isVideo, summary: draft.summary)
        items.insert(item, at: 0)
        persist()
        if saveToPhotos { await exportToPhotos(item) }
        else { message = "Saved in the app library." }
    }
    func exportToPhotos(_ item: MediaItem) async {
        if item.savedToPhotos { message = "This capture is already saved to Photos."; return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Saved in the app. Photos permission was not granted; Share still works."; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = item.created
                let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                request.addResource(with: item.isVideo ? .video : .photo, fileURL: item.url, options: options)
                if let live = item.liveURL {
                    request.addResource(with: .pairedVideo, fileURL: live, options: options)
                }
                if let raw = item.rawURL {
                    let rawOptions = PHAssetResourceCreationOptions(); rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                    request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
                }
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].savedToPhotos = true }
            persist(); message = "Saved to Photos and the app library."
        } catch { message = "Saved in the app, but Photos export failed: \(error.localizedDescription)" }
    }
    func deleteLocal(_ item: MediaItem) {
        do {
            for url in [item.url, item.liveURL, item.rawURL].compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            items.removeAll { $0.id == item.id }; persist()
            message = "Deleted the local copy. Photos was not changed."
        } catch { message = error.localizedDescription }
    }
    private func persist() {
        do { try JSONEncoder().encode(items).write(to: manifest, options: .atomic) }
        catch { message = "Capture exists, but the library index could not be saved: \(error.localizedDescription)" }
    }
}
