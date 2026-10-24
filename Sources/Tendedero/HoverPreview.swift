import AppKit
import SwiftUI

/// Kept below the card so the card remains a live drag source even while previewing.
@MainActor
final class HoverPreview {
    static let shared = HoverPreview()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var model: PreviewModel?
    private var explicitlyOpened = false
    private var pendingID: UUID?
    private var visibleID: UUID?
    private let delay: TimeInterval
    private let present: ((Pegged, Line, CGRect) -> Void)?
    var keepsLineOpen: Bool { explicitlyOpened || model?.playing == true }

    init(delay: TimeInterval = 0.12, present: ((Pegged, Line, CGRect) -> Void)? = nil) {
        self.delay = delay
        self.present = present
    }

    func contains(_ point: NSPoint) -> Bool { panel?.isVisible == true && panel!.frame.insetBy(dx: -12, dy: -16).contains(point) }
    func cancelClose() { closing?.cancel(); closing = nil }
    func cancelPending() { pending?.cancel(); pending = nil; pendingID = nil }

    func schedule(item: Pegged, line: Line, anchor: CGRect) {
        guard !keepsLineOpen else { return }
        cancelClose()
        guard pendingID != item.id, visibleID != item.id else { return }
        cancelPending()
        pendingID = item.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingID == item.id else { return }
            self.pending = nil
            self.pendingID = nil
            if let present = self.present { self.visibleID = item.id; present(item, line, anchor) }
            else { self.show(item: item, line: line, anchor: anchor) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func scheduleClose() {
        cancelPending()
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard !GrabView.isDragging, self?.keepsLineOpen != true else { return }
            self?.close()
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func close() {
        cancelPending()
        cancelClose()
        model?.cancel()
        visibleID = nil
        explicitlyOpened = false
        model = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func show(item: Pegged, line: Line, anchor: CGRect, playVideo: Bool = false, persistent: Bool = false) {
        guard !GrabView.isDragging, line.revealed else { return }
        close()
        visibleID = item.id
        explicitlyOpened = persistent
        let panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = item.text == nil ? "预览：\(item.url.lastPathComponent)" : "文本预览"
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(560, available.width - 40)
        let height: CGFloat = item.kind == .image || item.kind == .video || item.kind == .text ? 420 : 180
        panel.setFrame(CGRect(x: min(available.maxX - width - 12, max(available.minX + 12, anchor.midX - width / 2)),
                              y: max(available.minY + 12, anchor.minY - height - 16), width: width, height: height), display: false)
        // Show the name immediately; never stretch the small card thumbnail into a fake clear preview.
        let model = PreviewModel()
        model.playing = playVideo && item.kind == .video
        self.model = model
        panel.contentView = NSHostingView(rootView: PreviewContent(item: item, line: line, model: model))
        panel.orderFrontRegardless()
        model.load(item, pixels: Int(max(width, height) * (screen?.backingScaleFactor ?? 2)))
    }
}

private struct PreviewContent: View {
    let item: Pegged
    let line: Line
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(item.text == nil ? item.url.lastPathComponent : "文本 · \(item.text!.count) 字符")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭预览", systemImage: "xmark.circle", action: HoverPreview.shared.close).labelStyle(.iconOnly)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Label(item.text == nil ? "拖出文件" : "拖出文本", systemImage: "hand.draw")
                    .font(.caption).padding(6)
                    .overlay(GrabArea(item: item, line: line, isPreview: true))
                Spacer()
                Button("快速查看") { line.quickLook(item.id) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .onHover { inside in
            if inside { HoverPreview.shared.cancelClose() } else { HoverPreview.shared.scheduleClose() }
        }
        .accessibilityLabel("\(item.kind.title)预览")
    }

    @ViewBuilder private var content: some View {
            if let text = item.text {
                ScrollView { Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else if model.ready, item.kind == .text || item.kind == .video && model.playing {
                VStack(spacing: 6) {
                    EmbeddedPreview(url: item.url, text: model.text, autostarts: item.kind == .video)
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                VStack(spacing: 10) {
                    if let image = model.image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .overlay {
                                if item.kind == .image { GrabArea(item: item, line: line, isPreview: true) }
                            }
                    } else {
                        Image(systemName: item.kind.symbol).font(.largeTitle).foregroundStyle(.secondary)
                    }
                    if item.kind == .video, model.ready {
                        Button("播放视频", systemImage: "play.fill") { model.playing = true }
                    }
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
