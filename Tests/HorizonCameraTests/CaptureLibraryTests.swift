import XCTest
import Foundation
@testable import HorizonCamera

final class CaptureLibraryTests: XCTestCase {
    private func temporaryLibrary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCorruptIndexIsPreservedAndOriginalResourcesRecoverWithoutInventedPairing() throws {
        let directory = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedIndex = Data("{ interrupted library index".utf8)
        let manifest = directory.appendingPathComponent("library.json")
        try damagedIndex.write(to: manifest)
        // Opaque bytes exercise file/index recovery, not image or movie decoding.
        let resources = ["photo.heic": Data([1, 2]), "original.dng": Data([3, 4]), "paired.mov": Data([5, 6])]
        for (name, data) in resources { try data.write(to: directory.appendingPathComponent(name)) }

        let recovered = try MediaLibraryIndex.load(from: directory)
        XCTAssertEqual(Set(recovered.items.map(\.filename)), Set(resources.keys))
        XCTAssertTrue(recovered.items.allSatisfy { $0.rawFilename == nil && $0.liveFilename == nil })
        XCTAssertTrue(try XCTUnwrap(recovered.items.first { $0.filename == "paired.mov" }).isVideo)
        XCTAssertFalse(recovered.requiresBackupBeforeWrite)
        XCTAssertTrue(try XCTUnwrap(recovered.warning).contains("pairing could not be verified"))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = files.filter { $0.lastPathComponent.hasPrefix("library-corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), damagedIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        for (name, original) in resources {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), original)
        }
    }

    func testValidIndexRetainsRAWAndLivePairsWithoutRecoveringDuplicateSidecars() throws {
        let directory = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = MediaItem(filename: "raw-preview.jpg", rawFilename: "original.dng", isVideo: false, summary: "RAW")
        let live = MediaItem(filename: "live.heic", liveFilename: "live.mov", isVideo: false, summary: "Live")
        for name in [raw.filename, "original.dng", live.filename, "live.mov"] {
            try Data([7, 8, 9]).write(to: directory.appendingPathComponent(name))
        }
        let index = try JSONEncoder().encode([raw, live])
        let manifest = directory.appendingPathComponent("library.json")
        try index.write(to: manifest)

        let loaded = try MediaLibraryIndex.load(from: directory)
        XCTAssertEqual(loaded.items.count, 2)
        XCTAssertEqual(loaded.items.first { $0.id == raw.id }, raw)
        XCTAssertEqual(loaded.items.first { $0.id == live.id }, live)
        XCTAssertNil(loaded.warning)
        XCTAssertFalse(loaded.requiresBackupBeforeWrite)
        XCTAssertEqual(try Data(contentsOf: manifest), index)
    }

    func testRecoverySkipsEmptyResourcesAndDirectories() throws {
        let directory = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([10]).write(to: directory.appendingPathComponent("saved.jpg"))
        try Data().write(to: directory.appendingPathComponent("empty.dng"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("not-a-movie.mov"), withIntermediateDirectories: true)

        let recovered = try MediaLibraryIndex.load(from: directory)
        XCTAssertEqual(recovered.items.map(\.filename), ["saved.jpg"])
        XCTAssertNotNil(recovered.warning)
    }
}
