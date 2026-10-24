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

    func testSourceSortFilterPersistenceAndRemovalProtectsOriginal() async throws {
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
            line.setSort(.created)
            line.setFilter(.text)
            let restored = Line(defaults: defaults)
            XCTAssertEqual(restored.sourceID, source.id)
            XCTAssertEqual(restored.currentFolder?.sort, .created)
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
}
