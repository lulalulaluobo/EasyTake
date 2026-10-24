import AppKit
import XCTest
@testable import Suiqu

@MainActor
final class HoverResponsivenessTests: XCTestCase {
    func testRepeatedEnterAndPollDoNotRestartHoverDelay() async throws {
        let name = "SuiquHoverTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let line = Line(defaults: defaults)
        let item = Pegged(url: URL(fileURLWithPath: "/tmp/hover.txt"), kind: .text)
        var shown: [TimeInterval] = []
        let start = Date()
        let hover = HoverPreview(delay: 0.05, present: { _, _, _ in shown.append(Date().timeIntervalSince(start)) })
        for _ in 0..<12 {
            hover.schedule(item: item, line: line, anchor: .zero)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(shown.count, 1, "同一卡片的原生进入与轮询不能反复推迟或重建预览")
        if let elapsed = shown.first { print("Deduplicated hover activation seconds=\(elapsed)") }
        hover.close()
    }

    func testChangingOrLeavingHoverCancelsOldCandidate() async throws {
        let name = "SuiquHoverCancelTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let line = Line(defaults: defaults)
        let first = Pegged(url: URL(fileURLWithPath: "/tmp/first.txt"), kind: .text)
        let second = Pegged(url: URL(fileURLWithPath: "/tmp/second.txt"), kind: .text)
        var shown: [UUID] = []
        let hover = HoverPreview(delay: 0.05, present: { item, _, _ in shown.append(item.id) })
        hover.schedule(item: first, line: line, anchor: .zero)
        hover.schedule(item: second, line: line, anchor: .zero)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(shown, [second.id])
        hover.close()
        hover.schedule(item: first, line: line, anchor: .zero)
        hover.cancelPending()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(shown, [second.id])
    }

    func testPreviewDecoderDoesNotWaitForBlockedCardJobs() async {
        let started = expectation(description: "two card decoders are busy")
        started.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let loader = ThumbnailLoader { url, _, _ in
            if url.lastPathComponent.hasPrefix("blocked") {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return NSImage(size: NSSize(width: 32, height: 32))
        }
        for index in 0..<2 {
            loader.load(URL(fileURLWithPath: "/tmp/blocked\(index).png"), kind: .image, pixels: 320) { _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        let ready = expectation(description: "preview has its reserved decoder")
        let start = Date()
        let url = URL(fileURLWithPath: "/tmp/priority-preview.png")
        loader.load(url, kind: .image, pixels: 1100, purpose: .preview) { image in
            XCTAssertNotNil(image)
            XCTAssertTrue(loader.cachedImage(url, pixels: 1100) === image)
            print("Preview under blocked-card backlog seconds=\(Date().timeIntervalSince(start))")
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 1)
    }

    func testRealImageUsesClearPixelsAndWarmPreviewIsImmediatelyAvailable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuiquHoverImage-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let item = Pegged(url: url, kind: .image)
        let first = PreviewModel()
        let start = Date()
        first.load(item, pixels: 1120)
        while first.image == nil && Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.image?.size.width, 1120)
        let second = PreviewModel()
        second.load(item, pixels: 1120)
        XCTAssertTrue(second.image != nil && second.image === first.image)
        print("Real 1800x1100 PNG preview seconds=\(Date().timeIntervalSince(start)); warm cache available synchronously")
        let oldDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(5)], ofItemAtPath: url.path)
        let changed = PreviewModel()
        changed.load(Pegged(url: url, kind: .image, modified: oldDate), pixels: 1120)
        let refreshStart = Date()
        while (changed.image == nil || changed.image === first.image) && Date().timeIntervalSince(refreshStart) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(changed.image != nil && changed.image !== first.image, "后台校验应替换过期清晰缓存")
        first.cancel()
        second.cancel()
        changed.cancel()
    }
}
