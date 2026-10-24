import XCTest
@testable import Suiqu

final class FolderSourceTests: XCTestCase {
    func testSortUsesOnlyDateAddedWithStableNameAndMissingDatesLast() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let a = FolderEntry(url: URL(fileURLWithPath: "/a.txt"), kind: .text, modified: old, added: new, isPlaceholder: false)
        let b = FolderEntry(url: URL(fileURLWithPath: "/b.txt"), kind: .text, modified: new, added: old, isPlaceholder: false)
        let c = FolderEntry(url: URL(fileURLWithPath: "/c.txt"), kind: .text, modified: new, added: nil, isPlaceholder: false)
        let d = FolderEntry(url: URL(fileURLWithPath: "/d.txt"), kind: .text, modified: new, added: new, isPlaceholder: false)
        XCTAssertEqual([c, d, b, a].sorted(by: FolderScanner.precedes).map(\.url.lastPathComponent), ["a.txt", "d.txt", "b.txt", "c.txt"])
    }

    func testLegacySortFieldsAreIgnoredWithoutLosingSourceOrBookmark() throws {
        let source = try FolderSource(url: FileManager.default.temporaryDirectory)
        let data = try JSONEncoder().encode(source)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for oldSort in ["created", "modified"] {
            legacy["sort"] = oldSort
            let decoded = try JSONDecoder().decode(FolderSource.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(decoded, source)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            XCTAssertNil(saved["sort"])
        }
    }

    func testBookmarkRoundTripAndRootOnlySnapshotLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: child.appendingPathComponent("nested.txt"))
        for index in 0..<24 {
            let file = folder.appendingPathComponent(String(format: "%02d.txt", index))
            try Data("test".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 100))], ofItemAtPath: file.path)
        }
        let source = try FolderSource(url: folder)
        let decoded = try JSONDecoder().decode(FolderSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(try decoded.resolve().0.standardizedFileURL, folder.standardizedFileURL)
        let snapshot = try FolderScanner.scan(source, cancellation: ScanCancellation())
        defer { if snapshot.descriptor >= 0 { close(snapshot.descriptor) } }
        XCTAssertEqual(snapshot.scannedCount, 25)
        XCTAssertEqual(snapshot.entries.count, 20)
        XCTAssertFalse(snapshot.entries.contains { $0.url.lastPathComponent == "nested.txt" })
        // Modified dates were deliberately set to 1970. They must not affect Date Added.
        for entry in snapshot.entries {
            XCTAssertEqual(entry.added, try entry.url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
            XCTAssertNotNil(entry.added)
        }
        XCTAssertTrue(zip(snapshot.entries, snapshot.entries.dropFirst()).allSatisfy { FolderScanner.precedes($0, $1) })
        XCTAssertFalse(snapshot.limited)
    }

    func testCancelledScanAndUnavailableFolderFailWithoutDeletingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquCancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let source = try FolderSource(url: folder)
        let cancellation = ScanCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try FolderScanner.scan(source, cancellation: cancellation))
        XCTAssertEqual(try String(contentsOf: file), "keep")
    }

    func testFilterRunsBeforeSelectingTwentyNewestEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquFilter-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("old-image.png")
        try Data().write(to: image)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: image.path)
        for index in 0..<30 { try Data().write(to: folder.appendingPathComponent("\(index).txt")) }
        let snapshot = try FolderScanner.scan(FolderSource(url: folder), cancellation: ScanCancellation(), filter: .image)
        defer { if snapshot.descriptor >= 0 { close(snapshot.descriptor) } }
        XCTAssertEqual(snapshot.entries.map(\.url.lastPathComponent), ["old-image.png"])
    }

    func testLargeDirectoryScanIsBoundedAndReportsPartialResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquLarge-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<10_010 { try Data().write(to: folder.appendingPathComponent("\(index).txt")) }
        let source = try FolderSource(url: folder)
        let start = Date()
        let snapshot = try FolderScanner.scan(source, cancellation: ScanCancellation())
        defer { if snapshot.descriptor >= 0 { close(snapshot.descriptor) } }
        print("Large directory sample: scanned=\(snapshot.scannedCount), candidates=\(snapshot.entries.count), seconds=\(Date().timeIntervalSince(start))")
        XCTAssertLessThanOrEqual(snapshot.scannedCount, FolderScanner.scanLimit)
        XCTAssertEqual(snapshot.entries.count, 20)
        XCTAssertTrue(snapshot.limited)
    }
}
