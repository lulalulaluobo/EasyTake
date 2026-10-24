import AppKit
import XCTest
@testable import Suiqu

final class ClipboardAndRecentTests: XCTestCase {
    func testRecentAccessMergesByUsageTimeAndDeduplicatesBeforeLimit() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.txt")
        let records = RecentFiles.merge([
            RecentFileRecord(url: a, usedAt: Date(timeIntervalSince1970: 10), kind: .image),
            RecentFileRecord(url: b, usedAt: Date(timeIntervalSince1970: 30), kind: .text),
        ], [RecentFileRecord(url: a, usedAt: Date(timeIntervalSince1970: 40), kind: .image)], filter: nil)
        XCTAssertEqual(records.map(\.url), [a, b])
        XCTAssertEqual(records.first?.usedAt, Date(timeIntervalSince1970: 40))
        XCTAssertEqual(RecentFiles.merge(records, [], filter: .text).map(\.url), [b])
    }

    func testOwnedAssetCleanupCannotRemoveExternalUserFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquCache-\(UUID())")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquExternal-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: external) }
        try Data("original".utf8).write(to: external)
        let owned = try ClipboardAssets.save(Data("cache".utf8), extension: "txt", directory: directory)
        ClipboardAssets.remove(ClipboardRecord(url: external, kind: .text, ownedAsset: true), directory: directory)
        XCTAssertEqual(try String(contentsOf: external), "original")
        ClipboardAssets.remove(ClipboardRecord(url: owned, kind: .text, ownedAsset: true), directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    @MainActor func testPrivateClipboardMarkersAreRejectedAndTextUsesOwnPasteboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var received: [ClipboardRecord] = []
        let watcher = ClipboardWatcher(pasteboard: pasteboard, onRecord: { received.append($0) })
        watcher.start()
        let privateItem = NSPasteboardItem()
        privateItem.setString("private fixture", forType: .string)
        privateItem.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([privateItem])
        watcher.check()
        XCTAssertTrue(received.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("public fixture", forType: .string)
        watcher.check()
        let start = Date()
        while received.isEmpty && Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(25)) }
        watcher.stop()
        XCTAssertEqual(received.first?.text, "public fixture")
        XCTAssertEqual(received.first?.kind, .text)
        if let record = received.first { ClipboardAssets.remove(record) }
    }
}
