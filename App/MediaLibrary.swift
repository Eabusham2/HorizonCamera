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

enum MediaLibraryIndex {
    struct Loaded {
        let items: [MediaItem]
        let warning: String?
        let requiresBackupBeforeWrite: Bool
    }

    static func preserveDamagedIndex(in directory: URL) throws {
        let original = directory.appendingPathComponent("library.json")
        let backup = directory.appendingPathComponent("library-corrupt-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: original, to: backup)
    }

    static func load(from directory: URL) throws -> Loaded {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("library.json")
        var items: [MediaItem] = []
        var warnings: [String] = []
        var requiresBackup = false
        if manager.fileExists(atPath: manifest.path) {
            do {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: manifest))
                items = items.filter { manager.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            } catch {
                do {
                    try preserveDamagedIndex(in: directory)
                    warnings.append("The local capture index was unreadable. Its original contents were preserved.")
                } catch {
                    requiresBackup = true
                    warnings.append("The local capture index was unreadable and could not be backed up. It was left unchanged.")
                }
            }
        }
        let known = Set(items.flatMap { [$0.filename, $0.liveFilename, $0.rawFilename].compactMap { $0 } })
        var recovered = 0
        do {
            let files = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles])
            for url in files where !known.contains(url.lastPathComponent) && ["mov", "heic", "jpg", "dng"].contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
                var item = MediaItem(filename: url.lastPathComponent, isVideo: url.pathExtension.lowercased() == "mov", summary: "Recovered local capture")
                if let date = values.creationDate { item.created = date }
                items.append(item)
                recovered += 1
            }
        } catch {
            warnings.append("Local capture recovery failed: \(error.localizedDescription)")
        }
        if recovered > 0 {
            warnings.append("Recovered \(recovered) unindexed capture files. RAW and Live Photo resources may appear separately because their pairing could not be verified.")
        }
        items.sort { $0.created > $1.created }
        return Loaded(items: items, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
                      requiresBackupBeforeWrite: requiresBackup)
    }
}

@MainActor final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var message: String?
    private var exportsInProgress: Set<UUID> = []
    private var persistenceError: String?
    private var requiresIndexBackup = false
    private var manifest: URL { MediaFiles.directory.appendingPathComponent("library.json") }
    init() {
        do {
            let loaded = try MediaLibraryIndex.load(from: MediaFiles.directory)
            items = loaded.items
            requiresIndexBackup = loaded.requiresBackupBeforeWrite
            message = loaded.warning
        } catch { message = "Local library: \(error.localizedDescription)" }
    }
    func add(_ draft: MediaDraft, saveToPhotos: Bool) async {
        let item = MediaItem(filename: draft.url.lastPathComponent, liveFilename: draft.liveMovie?.lastPathComponent,
                             rawFilename: draft.raw?.lastPathComponent, isVideo: draft.isVideo, summary: draft.summary)
        items.insert(item, at: 0)
        let indexed = persist()
        if saveToPhotos { await exportToPhotos(item) }
        else if indexed { showMessage(nil) }
    }
    func exportToPhotos(_ item: MediaItem) async {
        guard let current = items.first(where: { $0.id == item.id }) else {
            showMessage("This capture is no longer in the local library."); return
        }
        if current.savedToPhotos { showMessage("This capture is already saved to Photos."); return }
        guard exportsInProgress.insert(current.id).inserted else {
            showMessage("This capture is already being saved to Photos."); return
        }
        defer { exportsInProgress.remove(current.id) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showMessage("Saved in the app. Photos permission was not granted; Share still works."); return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = current.created
                let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                if let raw = current.rawURL {
                    let rawOptions = PHAssetResourceCreationOptions(); rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                    rawOptions.shouldMoveFile = false
                    request.addResource(with: .photo, fileURL: raw, options: rawOptions)
                    request.addResource(with: .alternatePhoto, fileURL: current.url, options: options)
                } else {
                    request.addResource(with: current.isVideo ? .video : .photo, fileURL: current.url, options: options)
                    if let live = current.liveURL {
                        request.addResource(with: .pairedVideo, fileURL: live, options: options)
                    }
                }
            }
            if let index = items.firstIndex(where: { $0.id == current.id }) { items[index].savedToPhotos = true }
            if persist() { showMessage(nil) }
        } catch { showMessage("Saved in the app, but Photos export failed: \(error.localizedDescription)") }
    }
    func deleteLocal(_ item: MediaItem) {
        guard !exportsInProgress.contains(item.id) else {
            showMessage("Wait for this capture to finish saving to Photos before deleting its local copy."); return
        }
        do {
            for url in [item.url, item.liveURL, item.rawURL].compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            items.removeAll { $0.id == item.id }
            if persist() { showMessage(nil) }
        } catch { showMessage(error.localizedDescription) }
    }
    private func showMessage(_ text: String?) {
        let parts = [persistenceError, text].compactMap { $0 }
        message = parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    @discardableResult private func persist() -> Bool {
        do {
            if requiresIndexBackup {
                try MediaLibraryIndex.preserveDamagedIndex(in: MediaFiles.directory)
                requiresIndexBackup = false
            }
            try JSONEncoder().encode(items).write(to: manifest, options: .atomic)
            persistenceError = nil
            return true
        } catch {
            persistenceError = "The local library index could not be saved. Recent library changes may not survive relaunch: \(error.localizedDescription)"
            showMessage(nil)
            return false
        }
    }
}
