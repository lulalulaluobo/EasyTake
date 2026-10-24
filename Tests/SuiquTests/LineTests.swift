import AppKit
import XCTest
@testable import Suiqu

@MainActor
final class LineTests: XCTestCase {
    private func withDefaults(_ work: (UserDefaults) async throws -> Void) async throws {
        let name = "SuiquTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "soundOff")
        defer { defaults.removePersistentDomain(forName: name) }
        try await work(defaults)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition())
    }

    func testSourceFilterPersistenceAndRemovalProtectsOriginal() async throws {
        try await withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquLine-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("keep.txt")
            try Data("original".utf8).write(to: file)
            let source = try FolderSource(url: directory)
            let line = Line(defaults: defaults)
            XCTAssertTrue(line.isRecent)
            line.addFolder(source)
            line.setFilter(.text)
            let restored = Line(defaults: defaults)
            XCTAssertEqual(restored.sourceID, source.id)
            XCTAssertEqual(restored.currentFolder, source)
            XCTAssertEqual(restored.filter, .text)
            restored.removeSource(source.id)
            XCTAssertTrue(restored.isRecent)
            XCTAssertEqual(try String(contentsOf: file), "original")
            line.setVisible(false)
            restored.setVisible(false)
        }
    }

    func testClipboardFilteringAndClearingNeverDeletesUserFile() async throws {
        try await withDefaults { defaults in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquKeep-\(UUID()).txt")
            try Data("original".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let line = Line(defaults: defaults)
            line.selectSource(nil)
            let id = line.recordClipboard(ClipboardRecord(url: file, kind: .text))!
            line.setFilter(.image)
            XCTAssertTrue(line.items.isEmpty)
            line.setFilter(nil)
            XCTAssertEqual(line.items.first?.id, id)
            line.clear()
            await withCheckedContinuation { continuation in ClipboardAssets.queue.async { continuation.resume() } }
            XCTAssertEqual(try String(contentsOf: file), "original")
            XCTAssertTrue(Line(defaults: defaults).items.isEmpty)
        }
    }

    func testFolderUpdatesAndHiddenRefreshDoNotBecomeClipboardHistory() async throws {
        try await withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquRefresh-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.txt")
            try Data("a".utf8).write(to: first)
            let line = Line(defaults: defaults)
            line.addFolder(try FolderSource(url: directory))
            line.revealed = true
            line.setVisible(true)
            try await waitUntil { !line.loading && line.items.count == 1 }
            line.revealed = false
            line.setVisible(false)
            let second = directory.appendingPathComponent("second.txt")
            try Data("b".utf8).write(to: second)
            XCTAssertEqual(line.items.count, 1)
            line.revealed = true
            line.setVisible(true)
            try await waitUntil { !line.loading && line.items.count == 2 }
            try FileManager.default.moveItem(at: second, to: directory.appendingPathComponent("renamed.txt"))
            try await waitUntil { line.items.contains { $0.url.lastPathComponent == "renamed.txt" } }
            line.selectSource(nil)
            XCTAssertTrue(line.items.isEmpty)
            line.setVisible(false)
        }
    }

    func testMovedOldFileAppearsFirstAndEditsDoNotReorderByModifiedDate() async throws {
        try await withDefaults { defaults in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SuiquAdded-\(UUID())")
            let directory = root.appendingPathComponent("source")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let existing = directory.appendingPathComponent("existing.txt")
            try Data("existing".utf8).write(to: existing)
            let line = Line(defaults: defaults)
            line.addFolder(try FolderSource(url: directory))
            line.revealed = true
            line.setVisible(true)
            defer { line.revealed = false; line.setVisible(false) }
            try await waitUntil { line.items.count == 1 && !line.loading }
            // APFS Date Added may have whole-second precision. Separate the additions.
            try await Task.sleep(for: .milliseconds(1100))
            let outside = root.appendingPathComponent("old.txt")
            try Data("old document".utf8).write(to: outside)
            try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1),
                                  .modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: outside.path)
            let moved = directory.appendingPathComponent("moved.txt")
            try fm.moveItem(at: outside, to: moved)
            try await waitUntil { line.items.count == 2 && line.items.first?.url.lastPathComponent == "moved.txt" }
            let addedBefore = try existing.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
            try Data("edited existing".utf8).write(to: existing)
            let modifiedAfter = try URL(fileURLWithPath: existing.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try await waitUntil { line.items.last?.modified == modifiedAfter }
            XCTAssertEqual(line.items.map(\.url.lastPathComponent), ["moved.txt", "existing.txt"])
            // A fresh URL avoids comparing Foundation's cached resource values.
            XCTAssertEqual(try URL(fileURLWithPath: existing.path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate, addedBefore)
            try fm.removeItem(at: moved)
            try await waitUntil { line.items.map(\.url.lastPathComponent) == ["existing.txt"] }
            XCTAssertEqual(try String(contentsOf: existing), "edited existing")
        }
    }

    func testConfiguredDownloadsMatchesFinderDateAdded() async throws {
        guard ProcessInfo.processInfo.environment["SUIQU_VERIFY_DOWNLOADS"] == "1" else {
            throw XCTSkip("Read-only check of the user's configured Downloads source is opt-in")
        }
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let data = try XCTUnwrap(AppSettings.defaults.data(forKey: "folderSources"))
        let sources = try JSONDecoder().decode([FolderSource].self, from: data)
        let source = try XCTUnwrap(sources.first { $0.path == downloads.path })
        let files = try fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [.skipsHiddenFiles])
        let dates = try Dictionary(uniqueKeysWithValues: files.map { ($0, try $0.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate ?? .distantPast) })
        let expected = Array(files.sorted {
            dates[$0] == dates[$1] ? $0.lastPathComponent < $1.lastPathComponent : dates[$0]! > dates[$1]!
        }.prefix(20))
        try await withDefaults { defaults in
            defaults.set(data, forKey: "folderSources")
            defaults.set(source.id.uuidString, forKey: "selectedSource")
            defaults.set("all", forKey: "typeFilter")
            let line = Line(defaults: defaults)
            XCTAssertEqual(line.currentFolder?.id, source.id)
            line.revealed = true
            line.setVisible(true)
            defer { line.revealed = false; line.setVisible(false) }
            try await waitUntil { !line.loading }
            XCTAssertNil(line.sourceMessage)
            XCTAssertEqual(line.items.map(\.url), expected)
            print("Configured Downloads: \(files.count) entries, latest \(expected.count) all match Finder Date Added order")
        }
    }

    func testNewCaptureCannotReplaceOrTrimAnActiveDragSource() async throws {
        try await withDefaults { defaults in
            let line = Line(defaults: defaults)
            line.visibleCount = 1
            line.selectSource(nil)
            let first = ClipboardRecord(url: URL(fileURLWithPath: "/tmp/drag-source.txt"), kind: .text)
            line.recordClipboard(first)
            line.draggingID = first.id
            line.recordClipboard(ClipboardRecord(url: URL(fileURLWithPath: "/tmp/new.txt"), kind: .text))
            XCTAssertEqual(line.items.map(\.id), [first.id])
            line.setFilter(.image)
            XCTAssertNil(line.filter)
            line.selectSource(Line.recentID)
            XCTAssertTrue(line.isClipboard)
            line.draggingID = nil
            line.trimHistory()
            XCTAssertEqual(line.items.first?.url.lastPathComponent, "new.txt")
        }
    }

    func testImageCopyContainsOriginalPixelsAndFileReference() async throws {
        try await withDefaults { defaults in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquCopy-\(UUID()).png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 30,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let line = Line(defaults: defaults)
            line.selectSource(nil)
            let id = line.hang(url, quietly: true)!
            line.copy(id, pasteboard: pasteboard)
            try await waitUntil { pasteboard.data(forType: .png) != nil }
            XCTAssertEqual(pasteboard.string(forType: .fileURL), url.absoluteString)
            let copied = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
            XCTAssertEqual(copied.pixelsWide, 48)
            XCTAssertEqual(copied.pixelsHigh, 30)
            XCTAssertNotNil(pasteboard.string(forType: ClipboardWatcher.ownCopyType))
        }
    }

    func testPlainTextCopyUsesBodyAndRestoresAfterRestart() async throws {
        try await withDefaults { defaults in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let line = Line(defaults: defaults)
            line.selectSource(nil)
            let text = "第一行\n第二行"
            let record = ClipboardRecord(url: URL(fileURLWithPath: "/tmp/test-text-asset.txt"), kind: .text, text: text)
            line.recordClipboard(record)
            let restored = Line(defaults: defaults)
            XCTAssertEqual(restored.items.first?.text, text)
            restored.copy(record.id, pasteboard: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), text)
            XCTAssertNil(pasteboard.string(forType: .fileURL))
        }
    }
}
