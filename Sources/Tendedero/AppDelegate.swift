import AppKit
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher?
    private var recordingWatcher: ScreenshotWatcher?
    private var clipboardWatcher: ClipboardWatcher!
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var isRevealed = false
    private var pinned = false
    private var openedOnPurpose = false
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    private var hotScreen: NSScreen?
    private var awaySince: Date?
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []

    static var opensFromMenuBar: Bool {
        get { !AppSettings.defaults.bool(forKey: "menuBarRevealOff") }
        set { AppSettings.defaults.set(!newValue, forKey: "menuBarRevealOff") }
    }
    static var peeksAtNew: Bool {
        get { !AppSettings.defaults.bool(forKey: "quietHang") }
        set { AppSettings.defaults.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()
        setUpStatusItem()
        line.onSourcesMenu = { [weak self] in self?.showMenu(self?.sourcesMenu()) }
        line.onSortMenu = { [weak self] in self?.showMenu(self?.sortMenu()) }
        line.onSizeMenu = { [weak self] in self?.showMenu(self?.sizeMenu()) }
        line.onSettingsMenu = { [weak self] in self?.showMenu(self?.settingsMenu()) }
        line.onAddFolder = { [weak self] in self?.chooseFolder() }
        line.onDropFolder = { [weak self] url in self?.addFolder(url) }
        line.onHide = { [weak self] in self?.setRevealed(false) }
        line.onFall = { [weak self] item in self?.fall(item) }
        panel.onScroll = { [weak self] event in
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.$items.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &cancellables)
        clipboardWatcher = ClipboardWatcher(onRecord: { [weak self] record in self?.receiveRecord(record) },
            onError: { [weak self] message in self?.line.reportRecordingError(message) })
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }
        // Only the floating-thumbnail setting belongs to direct hanging; screenshot locations stay untouched.
        if Inbox.isEnabled { Inbox.apply() }
        else if Inbox.hasPendingRestore { Inbox.restore() }
        startWatcher()
        registerShortcut()
        watchMenuBarClicks()
        restoreSettingsOnTermination()
        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let screenshots = ScreenshotWatcher.screenshotFolder()
                    let recordings = ScreenshotWatcher.recordingFolder()
                    let recordingFolder: URL? = recordings == screenshots ? nil : recordings
                    if self.watcher?.folder != screenshots || self.recordingWatcher?.folder != recordingFolder {
                        self.startWatcher()
                    }
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self.openedOnPurpose = false }
                    if !self.openedOnPurpose, let screen = self.panel.screen, FullScreen.blocksLine(on: screen) {
                        self.setRevealed(false)
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel.placeOnScreen(); self?.updateCapacity() }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        line.setVisible(false)
        Inbox.restore()
    }

    private func startWatcher() {
        watcher?.stop()
        recordingWatcher?.stop()
        let recordings = ScreenshotWatcher.recordingFolder()
        let screenshots = ScreenshotWatcher.screenshotFolder()
        watcher = ScreenshotWatcher(folder: screenshots, acceptRecordings: recordings == screenshots,
            onNew: { [weak self] url in self?.hangCapture(url) }, onChange: {})
        watcher?.start()
        if recordings != screenshots {
            recordingWatcher = ScreenshotWatcher(folder: recordings, acceptRecordings: true,
                onNew: { [weak self] url in self?.hangCapture(url) }, onChange: {})
            recordingWatcher?.start()
        } else { recordingWatcher = nil }
    }

    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Inbox.restore(); exit(0) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func chooseFolder(replacing source: FolderSource? = nil) {
        guard !GrabView.isDragging else { return }
        line.choosingFolder = true
        defer { line.choosingFolder = false }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = source == nil ? "添加来源" : "重新授权"
        picker.message = "仅保存目录访问引用，显示直属文件；不移动或删除原件。"
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url { addFolder(url, replacing: source) }
    }

    private func addFolder(_ url: URL, replacing source: FolderSource? = nil) {
        guard !GrabView.isDragging else { return }
        line.choosingFolder = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> FolderSource in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                return try FolderSource(url: url, id: source?.id ?? UUID(), sort: source?.sort ?? .modified)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.line.choosingFolder = false
                switch result {
                case .success(let folder): self.line.addFolder(folder, replacing: source?.id)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "无法添加目录"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func showMenu(_ menu: NSMenu?) {
        guard let menu, !GrabView.isDragging else { return }
        GrabView.isShowingMenu = true
        HoverPreview.shared.close()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        GrabView.isShowingMenu = false
    }

    private func sourcesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if line.showRecent {
            let recent = ClosureMenuItem("最近访问") { [weak self] in self?.line.selectSource(Line.recentID) }
            recent.state = line.isRecent ? .on : .off
            menu.addItem(recent)
        }
        let clipboard = ClosureMenuItem("剪贴板与截图") { [weak self] in self?.line.selectSource(nil) }
        clipboard.state = line.sourceID == nil ? .on : .off
        menu.addItem(clipboard)
        for folder in line.folders {
            let item = ClosureMenuItem(folder.name) { [weak self] in self?.line.selectSource(folder.id) }
            item.state = line.sourceID == folder.id ? .on : .off
            item.toolTip = folder.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("添加文件夹来源…") { [weak self] in self?.chooseFolder() })
        if let source = line.currentFolder {
            menu.addItem(ClosureMenuItem("重新授权当前来源…") { [weak self] in self?.chooseFolder(replacing: source) })
            menu.addItem(ClosureMenuItem("移除当前来源（保留文件）") { [weak self] in self?.line.removeSource(source.id) })
        }
        return menu
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for sort in FolderSort.allCases {
            let item = ClosureMenuItem(sort.title) { [weak self] in self?.line.setSort(sort) }
            item.state = line.currentFolder?.sort == sort ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (size, title) in [(Layout.Size.small, "小卡片"), (.medium, "中卡片"), (.large, "大卡片")] {
            let item = ClosureMenuItem(title) { [weak self] in
                guard let self else { return }
                Layout.size = size
                self.line.cardSize = size
                self.panel.placeOnScreen(self.panel.screen)
                self.updateCapacity()
                self.line.reloadThumbnails()
            }
            item.state = Layout.size == size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        let recent = ClosureMenuItem("显示最近访问来源") { [weak self] in
            guard let self else { return }; self.line.setShowRecent(!self.line.showRecent)
        }
        recent.state = line.showRecent ? .on : .off
        menu.addItem(recent)
        let systemRecent = ClosureMenuItem("包含已授权目录的系统最近访问") { [weak self] in
            guard let self else { return }; self.line.setSystemRecent(!self.line.systemRecentEnabled)
        }
        systemRecent.state = line.systemRecentEnabled ? .on : .off
        menu.addItem(systemRecent)
        let capacity = NSMenuItem(title: "挂绳保留数量", action: nil, keyEquivalent: "")
        let capacities = NSMenu()
        let fit = ClosureMenuItem("与屏幕可显示数量相同") { [weak self] in Line.keepOnLine = nil; self?.line.trimHistory() }
        fit.state = Line.keepOnLine == nil ? .on : .off
        capacities.addItem(fit)
        for count in Line.keepChoices {
            let item = ClosureMenuItem("\(count) 项") { [weak self] in Line.keepOnLine = count; self?.line.trimHistory() }
            item.state = Line.keepOnLine == count ? .on : .off
            capacities.addItem(item)
        }
        capacity.submenu = capacities
        menu.addItem(capacity)
        let sound = ClosureMenuItem("声音") { [weak self] in self?.line.soundOn.toggle() }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)
        let login = ClosureMenuItem("登录时启动") {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法更改登录启动设置"
                alert.informativeText = "请将随取移至应用程序目录后重试。\n\(error.localizedDescription)"
                alert.runModal()
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let hover = ClosureMenuItem("顶边停留呼出") { Self.opensFromMenuBar.toggle() }
        hover.state = Self.opensFromMenuBar ? .on : .off
        menu.addItem(hover)
        let delay = NSMenuItem(title: "顶边停留时间", action: nil, keyEquivalent: "")
        let delays = NSMenu()
        for seconds in [0.3, 0.5, 0.8, 1.0, 1.5] {
            let item = ClosureMenuItem("\(seconds) 秒") { AppSettings.revealDelay = seconds }
            item.state = abs(AppSettings.revealDelay - seconds) < 0.01 ? .on : .off
            delays.addItem(item)
        }
        delay.submenu = delays
        menu.addItem(delay)
        menu.addItem(ClosureMenuItem("快捷键：\(Shortcut.current?.display ?? "未设置")…") { [weak self] in self?.changeShortcut() })
        let full = ClosureMenuItem("允许在全屏应用上方自动呼出") { FullScreen.showLineOver.toggle() }
        full.state = FullScreen.showLineOver ? .on : .off
        menu.addItem(full)
        menu.addItem(.separator())
        let clipboard = ClosureMenuItem("记录剪贴板（图片、文本及文件）") { [weak self] in
            ClipboardWatcher.isEnabled.toggle()
            if ClipboardWatcher.isEnabled { self?.clipboardWatcher.start() } else { self?.clipboardWatcher.stop() }
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        menu.addItem(clipboard)
        if let message = line.recordingMessage {
            let status = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let screenshots = ClosureMenuItem("截图直接挂起（关闭系统浮动缩略图）") { [weak self] in
            Inbox.isEnabled.toggle()
            if Inbox.isEnabled { Inbox.apply() } else { Inbox.restore() }
            self?.startWatcher()
        }
        screenshots.state = Inbox.isEnabled ? .on : .off
        menu.addItem(screenshots)
        if Inbox.hasPendingRestore {
            menu.addItem(ClosureMenuItem("恢复随取修改过的截图选项") { Inbox.isEnabled = false; Inbox.restore() })
        }
        let peek = ClosureMenuItem("新截图短暂展开挂绳") { Self.peeksAtNew.toggle() }
        peek.state = Self.peeksAtNew ? .on : .off
        menu.addItem(peek)
        return menu
    }

    private func registerShortcut() {
        hotKey = nil
        if let shortcut = Shortcut.current { hotKey = HotKey(shortcut) { [weak self] in self?.toggle() } }
    }

    private func changeShortcut() {
        hotKey = nil
        line.choosingFolder = true
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            self.line.choosingFolder = false
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                if result != nil && self.hotKey == nil { NSSound.beep(); Shortcut.current = previous }
            }
            self.registerShortcut()
        }
    }

    @objc private func toggle() {
        if isRevealed { setRevealed(false) }
        else {
            openedOnPurpose = true
            pinned = true
            panel.placeOnScreen()
            updateCapacity()
            setRevealed(true)
        }
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed, !GrabView.isDragging else { return }
        isRevealed = on
        line.revealed = on
        line.setVisible(on)
        awaySince = nil
        if on {
            line.scroll = 0
            panel.orderFrontRegardless()
        } else {
            pinned = false
            openedOnPurpose = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var height = screen.frame.maxY - screen.visibleFrame.maxY
        if height < 1 { height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSScreen.screens.contains(where: { NSMouseInRect(NSEvent.mouseLocation, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                self.setRevealed(false)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in handler(event); return event }) { clickMonitors.append(local) }
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screen.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }
        guard isRevealed else {
            let atEdge = screen.map { mouse.y >= $0.frame.maxY - 2 } ?? false
            if Self.opensFromMenuBar, let screen, atEdge, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                if hotScreen != screen { hotZoneSince = nil; hotScreen = screen }
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= AppSettings.revealDelay {
                    hotZoneSince = nil
                    panel.placeOnScreen(screen)
                    updateCapacity()
                    setRevealed(true)
                }
            } else { hotZoneSince = nil; hotScreen = nil }
            return
        }
        updateMousePassThrough(mouse)
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false) || HoverPreview.shared.contains(mouse)
        if inside && pinned { pinned = false }
        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || line.choosingFolder
            || line.pressedID != nil || QuickLook.shared.isVisible || now < peekUntil
        if inside || busy { awaySince = nil }
        else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= 0.5 { setRevealed(false) }
        }
    }

    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overContent = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        panel.ignoresMouseEvents = !overContent
    }

    private func updateCapacity() {
        line.visibleCount = max(1, min(12, Int((panel.frame.width - 200) / Layout.spacing)))
        line.trimHistory()
    }

    private func hangCapture(_ url: URL) {
        receiveRecord(ClipboardRecord(url: url, kind: FileKind.identify(url)), isCapture: true)
    }

    private func receiveRecord(_ record: ClipboardRecord, isCapture: Bool = false) {
        // Captures enter their own history without switching a folder source.
        let canShow = line.isClipboard && Self.peeksAtNew && !GrabView.isDragging
            && (line.filter == nil || line.filter == record.kind)
        let from = canShow && isCapture && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? captureRect(of: record.url) : nil
        guard let id = line.recordClipboard(record, flying: from != nil) else { return }
        guard canShow, !GrabView.isDragging else { return }
        let screen = LinePanel.screenUnderPointer()
        guard screen.map({ !FullScreen.blocksLine(on: $0) }) ?? false else { line.land(id); return }
        panel.placeOnScreen(screen)
        updateCapacity()
        peekUntil = Date().addingTimeInterval(2.5)
        setRevealed(true)
        guard let from else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fly(id, from: from) }
    }

    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width, visible: line.visibleCount, scroll: line.scroll)
        let cardTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2, y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id), let item = line.items.first(where: { $0.id == id }) else { line.land(id); return }
        ThumbnailLoader.shared.load(item.url, kind: item.kind, pixels: 1500) { [weak self] image in
            guard let self, self.isRevealed, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { self?.line.land(id); return }
            CaptureFlight.fly(image: cg, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in self?.line.land(id) }
        }
    }

    private func fall(_ item: Pegged) {
        guard isRevealed, let screen = panel.screen, let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "随取")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "随取 · \(line.sourceTitle) · \(line.liveCount) 项"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ClosureMenuItem(isRevealed ? "收起挂绳" : "展开挂绳") { [weak self] in self?.toggle() })
        for (title, submenu) in [("来源", sourcesMenu()), ("卡片大小", sizeMenu()), ("设置", settingsMenu())] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if line.currentFolder != nil {
            let item = NSMenuItem(title: "排序", action: nil, keyEquivalent: "")
            item.submenu = sortMenu()
            menu.addItem(item)
        } else if line.isClipboard {
            menu.addItem(ClosureMenuItem("清空剪贴板历史（保留原件）") { [weak self] in self?.line.clear() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出随取", key: "q") { NSApp.terminate(nil) })
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.take(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.release(panel) }
}
