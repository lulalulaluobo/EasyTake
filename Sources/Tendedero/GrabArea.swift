import AppKit
import SwiftUI

/// Native copy-only drag source shared by cards and the large hover preview.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    var isPreview = false

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        view.url = item.url
        view.text = item.text
        view.dragImage = item.thumb
        view.canDiscard = item.sourceID == nil && !isPreview
        view.onHover = { hovering, frame in
            if isPreview {
                if hovering { HoverPreview.shared.cancelClose() } else { HoverPreview.shared.scheduleClose() }
            } else if hovering {
                HoverPreview.shared.schedule(item: item, line: line, anchor: frame)
            } else { HoverPreview.shared.scheduleClose() }
        }
        view.onMouseDown = { HoverPreview.shared.cancelPending() }
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = {
            line.draggingID = id
            if !isPreview { HoverPreview.shared.close() }
        }
        view.onDragEnd = { succeeded in
            line.draggingID = nil
            if succeeded { line.recordUsage(item) }
            HoverPreview.shared.close()
            line.refreshSource()
        }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if item.text == nil {
                menu.addItem(ClosureMenuItem("复制绝对路径") { line.copyPath(id) })
                menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            }
            if item.kind == .image || item.kind == .video {
                menu.addItem(ClosureMenuItem(item.kind == .image ? "标注" : "裁剪") { line.markup(id) })
            }
            if item.sourceID == nil {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("移除历史（保留原件）") { line.discard(id) })
            }
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var text: String?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: (Bool) -> Void = { _ in }
    var canDiscard = false
    var onHover: (Bool, CGRect) -> Void = { _, _ in }
    var onMouseDown: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false
    /// A click copies only once it is clear it is not the first half of a
    /// double click, which opens the photo and must leave the clipboard alone.
    private var clickTimer: Timer?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !Self.isDragging, let window else { return }
        onHover(true, window.convertToScreen(convert(bounds, to: nil)))
    }

    override func mouseExited(with event: NSEvent) { onHover(false, .zero) }

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        if event.clickCount > 1 {
            clickTimer?.invalidate()
            clickTimer = nil
        }
        if canDiscard && isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()
        clickTimer?.invalidate()
        Self.isDragging = true
        onDragStart()

        let payload: NSPasteboardWriting = text.map { $0 as NSString } ?? (url as NSURL)
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            // Waits as long as the system lets a second click count as a double click.
            clickTimer?.invalidate()
            // The copy goes ahead even if the line redraws this view meanwhile.
            let copy = onClick
            let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clickTimer = nil
                    copy()
                }
            }
            // Keeps time while a menu or a drag runs the loop in another mode.
            RunLoop.main.add(timer, forMode: .common)
            clickTimer = timer
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        HoverPreview.shared.cancelPending()
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // A destination's move/delete result never authorizes deleting the source.
        onDragEnd(operation.contains(.copy))
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
