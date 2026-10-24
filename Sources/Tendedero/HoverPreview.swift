import AppKit
import SwiftUI

/// Kept below the card so the card remains a live drag source even while previewing.
@MainActor
final class HoverPreview {
    static let shared = HoverPreview()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var thumbnail: Operation?
    private var requestID = UUID()

    func contains(_ point: NSPoint) -> Bool { panel?.isVisible == true && panel!.frame.insetBy(dx: -12, dy: -16).contains(point) }
    func cancelClose() { closing?.cancel(); closing = nil }
    func cancelPending() { pending?.cancel(); pending = nil }

    func schedule(item: Pegged, line: Line, anchor: CGRect) {
        cancelClose()
        cancelPending()
        let work = DispatchWorkItem { [weak self] in self?.show(item: item, line: line, anchor: anchor) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func scheduleClose() {
        cancelPending()
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard !GrabView.isDragging else { return }
            self?.close()
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func close() {
        cancelPending()
        cancelClose()
        thumbnail?.cancel()
        thumbnail = nil
        requestID = UUID()
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(item: Pegged, line: Line, anchor: CGRect) {
        guard !GrabView.isDragging, line.revealed else { return }
        close()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(560, available.width - 40)
        let height: CGFloat = item.kind == .image || item.kind == .video ? 380 : 160
        panel.setFrame(CGRect(x: min(available.maxX - width - 12, max(available.minX + 12, anchor.midX - width / 2)),
                              y: max(available.minY + 12, anchor.minY - height - 16), width: width, height: height), display: false)
        // Show the name immediately; never stretch the small card thumbnail into a fake clear preview.
        panel.contentView = NSHostingView(rootView: PreviewContent(item: item, line: line, image: nil))
        panel.orderFrontRegardless()
        guard !item.isPlaceholder, item.kind == .image || item.kind == .video else { return }
        let request = UUID()
        requestID = request
        thumbnail = ThumbnailLoader.shared.load(item.url, kind: item.kind,
            pixels: Int(max(width, height) * (screen?.backingScaleFactor ?? 2)), modified: item.modified) { [weak self] image in
                guard let self, self.requestID == request else { return }
                self.panel?.contentView = NSHostingView(rootView: PreviewContent(item: item, line: line, image: image))
            }
    }
}

private struct PreviewContent: View {
    let item: Pegged
    let line: Line
    let image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: item.isPlaceholder ? "icloud.and.arrow.down" : item.kind.symbol)
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(item.isPlaceholder ? "文件尚未下载，可在访达中下载后预览" : "双击打开 · 右键快速预览")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.url.lastPathComponent).font(.callout).lineLimit(2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(GrabArea(item: item, line: line, isPreview: true))
        .accessibilityLabel("\(item.kind.title)：\(item.url.lastPathComponent)")
    }
}
