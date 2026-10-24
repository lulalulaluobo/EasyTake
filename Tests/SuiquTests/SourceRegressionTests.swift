import AppKit
import SwiftUI
import XCTest
@testable import Suiqu

@MainActor
final class SourceRegressionTests: XCTestCase {
    func testOrdinaryAppBookmarkResolvesWithoutScopeToken() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquBookmark-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertEqual(try FileBookmark.resolve(data).0.standardizedFileURL, url.standardizedFileURL)
    }

    func testMenuActionWaitsForTrackingCallToReturn() async throws {
        var fired = false
        let item = ClosureMenuItem("添加来源") { fired = true }
        NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        XCTAssertFalse(fired)
        for _ in 0..<10 where !fired { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(fired)
    }

    func testPixPinImageSurvivesInvalidTemporaryFileURL() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = image.representation(using: .png, properties: [:])!
        var record: ClipboardRecord?
        var error: String?
        let watcher = ClipboardWatcher(pasteboard: pasteboard, onRecord: { record = $0 }, onError: { error = $0 })
        watcher.start()
        let entry = NSPasteboardItem()
        entry.setString("file:///tmp/nonexistent-pixpin-\(UUID()).png", forType: .fileURL)
        entry.setString("fixture", forType: .init("com.depthpicture.pixpin.metadata"))
        entry.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
        watcher.check()
        let start = Date()
        while record == nil && error == nil && Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(25)) }
        watcher.stop()
        XCTAssertNil(error)
        XCTAssertEqual(record?.kind, .image)
        XCTAssertEqual(record?.ownedAsset, true)
        if let record {
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.url.path))
            ClipboardAssets.remove(record)
        }
    }

    func testSystemRecentQueryWorksWithoutCustomFolderSources() async throws {
        let name = "SuiquRecentTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let recent = RecentFiles(defaults: defaults)
        var finalMessage: String?
        var displayedCount = 0
        recent.start(sources: [], systemEnabled: true, filter: nil) { records, message in
            displayedCount = records.count
            if let message, !message.hasPrefix("正在") { finalMessage = message }
        }
        let start = Date()
        while finalMessage == nil && Date().timeIntervalSince(start) < 6 { try await Task.sleep(for: .milliseconds(25)) }
        recent.stop()
        XCTAssertNotNil(finalMessage)
        XCTAssertFalse(finalMessage?.contains("先添加") == true)
        XCTAssertFalse(finalMessage?.contains("超时") == true)
        if recent.indexedResultCount > 0 { XCTAssertGreaterThan(displayedCount, 0, "系统有索引结果时不能因读取 API 错误而显示空列表") }
    }

    func testTextPreviewPreparesFileWithoutStartingPlayback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquPreview-\(UUID()).txt")
        try "可滚动阅读的全文\n第二行".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PreviewModel()
        model.load(Pegged(url: url, kind: .text), pixels: 1100)
        let start = Date()
        while !model.ready && Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(model.ready)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.text, "可滚动阅读的全文\n第二行")
        XCTAssertFalse(model.playing)
        model.cancel()
    }

    func testClosingPreviewStopsPlaybackAndRejectsLateResults() async throws {
        let model = PreviewModel()
        model.playing = true
        model.load(Pegged(url: URL(fileURLWithPath: "/tmp/missing-\(UUID()).mp4"), kind: .video), pixels: 1100)
        model.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.playing)
        XCTAssertFalse(model.ready)
        XCTAssertNil(model.image)
    }

    func testTextPreviewReadsUTF16AndReportsTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquEncoding-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "中文文本\n第二行".data(using: .utf16)!.write(to: url)
        XCTAssertEqual(try PreviewText.read(url).content, "中文文本\n第二行")
        try Data(repeating: 97, count: PreviewText.maxBytes + 10).write(to: url)
        let limited = try PreviewText.read(url)
        XCTAssertTrue(limited.truncated)
        XCTAssertEqual(limited.content.utf8.count, PreviewText.maxBytes)
    }

    func testRepeatedTextPreviewHostingAndWindowTeardown() async {
        _ = NSApplication.shared
        for _ in 0..<30 {
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 420),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: EmbeddedPreview(url: URL(fileURLWithPath: "/tmp/fixture.txt"), text: "预览文字\n第二行"))
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                window.contentView = nil
                window.close()
            }
            await Task.yield()
        }
    }

    func testRepeatedVideoPreviewHostingAndEarlyTeardown() async {
        _ = NSApplication.shared
        for _ in 0..<15 {
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 420),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: EmbeddedPreview(url: URL(fileURLWithPath: "/tmp/preview-early-close.mp4"), autostarts: true))
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                window.contentView = nil
                window.close()
            }
            await Task.yield()
        }
    }
}
