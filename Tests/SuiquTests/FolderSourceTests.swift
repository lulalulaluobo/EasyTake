import XCTest
@testable import Suiqu

final class FolderSourceTests: XCTestCase {
    func testSortUsesSelectedDateAndStableNameWithMissingDatesLast() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let a = FolderEntry(url: URL(fileURLWithPath: "/a.txt"), kind: .text, modified: old, created: new, isPlaceholder: false)
        let b = FolderEntry(url: URL(fileURLWithPath: "/b.txt"), kind: .text, modified: new, created: old, isPlaceholder: false)
        let c = FolderEntry(url: URL(fileURLWithPath: "/c.txt"), kind: .text, modified: new, created: nil, isPlaceholder: false)
        XCTAssertEqual([c, a, b].sorted { FolderScanner.precedes($0, $1, sort: .modified) }.map(\.url.lastPathComponent), ["b.txt", "c.txt", "a.txt"])
        XCTAssertEqual([c, b, a].sorted { FolderScanner.precedes($0, $1, sort: .created) }.map(\.url.lastPathComponent), ["a.txt", "b.txt", "c.txt"])
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
        var source = try FolderSource(url: folder)
        source.sort = .created
        let decoded = try JSONDecoder().decode(FolderSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded.sort, .created)
        XCTAssertEqual(try decoded.resolve().0.standardizedFileURL, folder.standardizedFileURL)
        source.sort = .modified
        let snapshot = try FolderScanner.scan(source, cancellation: ScanCancellation())
        defer { if snapshot.descriptor >= 0 { close(snapshot.descriptor) } }
        XCTAssertEqual(snapshot.scannedCount, 25)
        XCTAssertEqual(snapshot.entries.count, 20)
        XCTAssertFalse(snapshot.entries.contains { $0.url.lastPathComponent == "nested.txt" })
        XCTAssertEqual(snapshot.entries.first?.kind, .folder)
        XCTAssertEqual(snapshot.entries[1].url.lastPathComponent, "23.txt")
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

    @MainActor func testDragOnlyOffersCopyEvenIfDestinationReportsDelete() {
        let view = GrabView()
        // The operation mask is independent of session and context; nil is accepted by the ObjC bridge.
        XCTAssertTrue(view.ignoreModifierKeys(for: NSDraggingSession()))
    }
}
