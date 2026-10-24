import AppKit
import Combine
import os

let log = Logger(subsystem: "local.suiqu.app", category: "line")

/// A reference to a user file. Removing a card never removes its file.
struct Pegged: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumb: NSImage
    let kind: FileKind
    let sourceID: UUID?
    let modified: Date?
    let isPlaceholder: Bool
    let text: String?
    let ownedAsset: Bool
    let tilt: Double
    var falling = false
    var flying = false
    var isRecording: Bool { kind == .video }

    init(url: URL, thumb: NSImage? = nil, id: UUID = UUID(), kind: FileKind? = nil,
         sourceID: UUID? = nil, modified: Date? = nil, isPlaceholder: Bool = false,
         text: String? = nil, ownedAsset: Bool = false, tilt: Double = .random(in: -2.5...2.5)) {
        self.id = id
        self.url = url
        self.kind = kind ?? FileKind.identify(url)
        self.thumb = thumb ?? NSImage(systemSymbolName: self.kind.symbol, accessibilityDescription: self.kind.title) ?? NSImage()
        self.sourceID = sourceID
        self.modified = modified
        self.isPlaceholder = isPlaceholder
        self.text = text
        self.ownedAsset = ownedAsset
        self.tilt = tilt
    }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.modified == b.modified && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

@MainActor
final class Line: ObservableObject {
    static let recentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var folders: [FolderSource] = []
    @Published private(set) var sourceID: UUID?
    @Published private(set) var loading = false
    @Published private(set) var sourceMessage: String?
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    @Published var revealed = false
    @Published var scroll: CGFloat = 0
    @Published var cardSize = Layout.size
    @Published private(set) var filter: FileKind?
    @Published private(set) var recordingMessage: String?
    @Published var clipboardRecording = ClipboardWatcher.isEnabled

    var hitRects: [UUID: CGRect] = [:]
    var visibleCount = 8
    var choosingFolder = false
    var onFall: ((Pegged) -> Void)?
    var onSourcesMenu: () -> Void = {}
    var onSizeMenu: () -> Void = {}
    var onSettingsMenu: () -> Void = {}
    var onAddFolder: () -> Void = {}
    var onDropFolder: (URL) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onToggleClipboard: () -> Void = {}

    var currentFolder: FolderSource? { folders.first { $0.id == sourceID } }
    var isRecent: Bool { sourceID == Self.recentID }
    var isClipboard: Bool { sourceID == nil }
    var sourceTitle: String { isRecent ? "最近访问" : currentFolder?.name ?? "剪贴板与截图" }
    var showRecent: Bool { !defaults.bool(forKey: "recentHidden") }
    var systemRecentEnabled: Bool { !defaults.bool(forKey: "systemRecentOff") }
    var liveCount: Int { items.filter { !$0.falling }.count }
    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    static let keepChoices = [25, 50, 100]
    static var keepOnLine: Int? {
        get {
            let count = AppSettings.defaults.integer(forKey: "keepOnLine")
            return keepChoices.contains(count) ? count : nil
        }
        set { AppSettings.defaults.set(newValue ?? 0, forKey: "keepOnLine") }
    }

    private var captures: [Pegged] = []
    private var candidates: [Pegged] = []
    private let defaults: UserDefaults
    private let recentFiles: RecentFiles
    private var scanToken: ScanCancellation?
    private var generation = UUID()
    private var folderAccess: FolderAccess?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var rescanTimer: Timer?
    private var pendingScan: DispatchWorkItem?
    private var thumbnailTasks: [Operation] = []

    init(defaults: UserDefaults = AppSettings.defaults) {
        self.defaults = defaults
        self.recentFiles = RecentFiles(defaults: defaults)
        self.filter = defaults.string(forKey: "typeFilter").flatMap(FileKind.init(rawValue:))
        if let data = defaults.data(forKey: "folderSources") {
            do { folders = try JSONDecoder().decode([FolderSource].self, from: data) }
            catch { sourceMessage = "来源配置无法读取，请重新添加目录。" }
        }
        sourceID = showRecent ? Self.recentID : nil
        if let saved = defaults.string(forKey: "selectedSource") {
            if saved == "clipboard" { sourceID = nil }
            else if let id = UUID(uuidString: saved), folders.contains(where: { $0.id == id }) || id == Self.recentID && showRecent { sourceID = id }
        }
        if let data = defaults.data(forKey: "clipboardRecords"), let records = try? JSONDecoder().decode([ClipboardRecord].self, from: data) {
            captures = records.suffix(100).map { Pegged(url: $0.url, id: $0.id, kind: $0.kind, text: $0.text, ownedAsset: $0.ownedAsset) }
        } else {
            let paths = defaults.stringArray(forKey: "pegged") ?? []
            captures = paths.suffix(100).map { Pegged(url: URL(fileURLWithPath: $0)) }
        }
        if isClipboard { candidates = Array(captures.reversed()); publishCandidates() }
        scheduleGust()
    }

    func addFolder(_ source: FolderSource, replacing id: UUID? = nil) {
        guard draggingID == nil else { return }
        if let id, let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index] = source
        } else if let existing = folders.first(where: { $0.path == source.path }) {
            selectSource(existing.id)
            return
        } else { folders.append(source) }
        saveSources()
        selectSource(source.id)
    }

    func removeSource(_ id: UUID) {
        guard draggingID == nil else { return }
        folders.removeAll { $0.id == id }
        saveSources()
        if sourceID == id { selectSource(showRecent ? Self.recentID : nil) }
    }

    func selectSource(_ id: UUID?) {
        guard draggingID == nil, id == nil || id == Self.recentID && showRecent || folders.contains(where: { $0.id == id }) else { return }
        HoverPreview.shared.close()
        QuickLook.shared.close()
        stopFolderWork()
        recentFiles.stop()
        sourceID = id
        defaults.set(id?.uuidString ?? "clipboard", forKey: "selectedSource")
        hitRects = [:]
        scroll = 0
        candidates = id == nil ? Array(captures.reversed()) : []
        publishCandidates()
        sourceMessage = nil
        if revealed { refreshSource() }
    }

    func setFilter(_ kind: FileKind?) {
        guard draggingID == nil else { return }
        filter = kind
        defaults.set(kind?.rawValue ?? "all", forKey: "typeFilter")
        HoverPreview.shared.close()
        scroll = 0
        publishCandidates()
        if revealed { refreshSource() }
    }

    func setShowRecent(_ visible: Bool) {
        guard draggingID == nil else { return }
        defaults.set(!visible, forKey: "recentHidden")
        if !visible && isRecent { selectSource(nil) }
        objectWillChange.send()
    }

    func setSystemRecent(_ enabled: Bool) {
        defaults.set(!enabled, forKey: "systemRecentOff")
        if isRecent { refreshSource() }
    }

    private func publishCandidates() {
        guard draggingID == nil else { return }
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let next = candidates.filter { filter == nil || $0.kind == filter }.map { candidate in
            var candidate = candidate
            if let old = previous[candidate.id], old.modified == candidate.modified { candidate.thumb = old.thumb }
            return candidate
        }
        if items != next { items = next }
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        scroll = min(scroll, most)
    }

    func setVisible(_ visible: Bool) {
        if visible { refreshSource() }
        else {
            stopFolderWork()
            recentFiles.stop()
            HoverPreview.shared.close()
        }
    }

    func refreshSource() {
        guard revealed, draggingID == nil, pressedID == nil else { return }
        if isRecent {
            recentFiles.start(sources: folders, systemEnabled: systemRecentEnabled, filter: filter) { [weak self] records, message in
                guard let self, self.isRecent, self.revealed, self.draggingID == nil else { return }
                let old = Dictionary(self.items.map { ($0.url, $0.id) }, uniquingKeysWith: { first, _ in first })
                self.candidates = records.map { Pegged(url: $0.url, id: old[$0.url] ?? UUID(), kind: $0.kind, sourceID: Self.recentID) }
                self.sourceMessage = message
                self.publishCandidates()
                self.reloadThumbnails()
            }
            return
        }
        guard let folder = currentFolder else {
            candidates = Array(captures.reversed())
            publishCandidates()
            reloadThumbnails()
            return
        }
        scanToken?.cancel()
        let token = ScanCancellation()
        scanToken = token
        let request = UUID()
        generation = request
        loading = true
        sourceMessage = nil
        let selectedFilter = filter
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FolderScanner.scan(folder, cancellation: token, filter: selectedFilter) }
            DispatchQueue.main.async {
                guard let self, self.generation == request, self.revealed, !token.isCancelled else {
                    if case let .success(snapshot) = result, snapshot.descriptor >= 0 { close(snapshot.descriptor) }
                    return
                }
                self.loading = false
                switch result {
                case .success(let snapshot):
                    if self.draggingID != nil || self.pressedID != nil {
                        if snapshot.descriptor >= 0 { close(snapshot.descriptor) }
                        return
                    }
                    self.adopt(snapshot, source: folder)
                case .failure(let error):
                    self.sourceMessage = "目录不可用：\(error.localizedDescription) 可重试或在来源菜单重新授权。"
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == request, self.loading else { return }
            token.cancel()
            self.loading = false
            self.sourceMessage = "目录读取超时，可重试或切换来源。"
        }
    }

    private func adopt(_ snapshot: FolderSnapshot, source: FolderSource) {
        directoryWatch?.cancel()
        directoryWatch = nil
        folderAccess = snapshot.access
        if let refreshed = snapshot.refreshedSource,
           let index = folders.firstIndex(where: { $0.id == source.id }) {
            folders[index] = refreshed
            saveSources()
        }
        let old = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        candidates = snapshot.entries.map { entry in
            let prior = old[entry.url]
            return Pegged(url: entry.url, thumb: prior?.modified == entry.modified ? prior?.thumb : nil,
                id: prior?.id ?? UUID(), kind: entry.kind, sourceID: source.id,
                modified: entry.modified, isPlaceholder: entry.isPlaceholder, tilt: prior?.tilt ?? .random(in: -2.5...2.5))
        }
        publishCandidates()
        if snapshot.limited {
            sourceMessage = "已扫描 \(snapshot.scannedCount) 项，显示其中最近 20 项；目录过大，结果可能不完整。"
        }
        if snapshot.descriptor >= 0 {
            let descriptor = snapshot.descriptor
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            watcher.setEventHandler { [weak self] in self?.scheduleRefresh() }
            watcher.setCancelHandler { close(descriptor) }
            directoryWatch = watcher
            watcher.resume()
        }
        // Vnode events cover entry changes; polling also notices writes to existing files.
        if rescanTimer == nil {
            rescanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.loading, self.draggingID == nil else { return }
                    self.refreshSource()
                }
            }
        }
        if items.contains(where: { old[$0.url]?.modified != $0.modified || old[$0.url] == nil }) { reloadThumbnails() }
    }

    private func scheduleRefresh() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshSource() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func stopFolderWork() {
        generation = UUID()
        scanToken?.cancel()
        scanToken = nil
        pendingScan?.cancel()
        pendingScan = nil
        rescanTimer?.invalidate()
        rescanTimer = nil
        directoryWatch?.cancel()
        directoryWatch = nil
        folderAccess = nil
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        loading = false
    }

    private func saveSources() {
        do { defaults.set(try JSONEncoder().encode(folders), forKey: "folderSources") }
        catch { sourceMessage = "无法保存来源：\(error.localizedDescription)" }
    }

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        recordClipboard(ClipboardRecord(url: url, kind: FileKind.identify(url)), flying: flying, quietly: quietly)
    }

    @discardableResult
    func recordClipboard(_ record: ClipboardRecord, flying: Bool = false, quietly: Bool = false) -> UUID? {
        guard !captures.contains(where: { $0.url == record.url }),
              record.text == nil || captures.last?.text != record.text else {
            ClipboardAssets.queue.async { ClipboardAssets.remove(record) }
            return nil
        }
        var item = Pegged(url: record.url, id: record.id, kind: record.kind, text: record.text, ownedAsset: record.ownedAsset)
        item.flying = flying
        captures.append(item)
        trimHistory()
        saveCaptures()
        if isClipboard, draggingID == nil {
            candidates = Array(captures.reversed())
            publishCandidates()
            scroll = 0
            if item.text == nil { loadThumbnail(item) }
        }
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    private var historyLimit: Int {
        let saved = defaults.integer(forKey: "keepOnLine")
        return Self.keepChoices.contains(saved) ? saved : max(1, visibleCount)
    }

    func trimHistory() {
        guard draggingID == nil else { return }
        let count = max(0, captures.count - historyLimit)
        let removed = Array(captures.prefix(count))
        captures.removeFirst(count)
        cleanAssets(removed)
        if isClipboard { candidates = Array(captures.reversed()); publishCandidates() }
        saveCaptures()
    }

    func reportRecordingError(_ message: String) { recordingMessage = message }

    private func cleanAssets(_ items: [Pegged]) {
        let records = items.map { ClipboardRecord(id: $0.id, url: $0.url, kind: $0.kind, text: $0.text, ownedAsset: $0.ownedAsset) }
        ClipboardAssets.queue.async { records.forEach { ClipboardAssets.remove($0) } }
    }

    func land(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].flying = false }
        if let i = captures.firstIndex(where: { $0.id == id }) { captures[i].flying = false }
    }

    func discard(_ id: UUID, quietly: Bool = false) {
        guard isClipboard, draggingID == nil, let item = items.first(where: { $0.id == id }) else { return }
        HoverPreview.shared.close()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { onFall?(item) }
        captures.removeAll { $0.id == id }
        candidates = Array(captures.reversed())
        publishCandidates()
        cleanAssets([item])
        hitRects[id] = nil
        saveCaptures()
        if !quietly { play("Pop", volume: 0.25) }
    }

    func clear() {
        guard isClipboard, draggingID == nil else { return }
        HoverPreview.shared.close()
        QuickLook.shared.close()
        cleanAssets(captures)
        captures = []
        candidates = []
        items = []
        saveCaptures()
    }

    func prune() {
        if currentFolder != nil { scheduleRefresh() }
    }

    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        scroll = min(most, max(0, scroll + delta))
        HoverPreview.shared.close()
    }

    func copy(_ id: UUID, pasteboard pb: NSPasteboard = .general) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        entry.setString("1", forType: ClipboardWatcher.ownCopyType)
        if let text = item.text { entry.setString(text, forType: .string) }
        else { entry.setString(item.url.absoluteString, forType: .fileURL) }
        pb.clearContents()
        pb.writeObjects([entry])
        if item.kind == .image, !item.isPlaceholder {
            let count = pb.changeCount
            let pasteboardName = pb.name.rawValue
            ClipboardAssets.queue.async {
                let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
                guard values?.ubiquitousItemDownloadingStatus != .notDownloaded,
                      let size = values?.fileSize, size <= ClipboardAssets.maxImageBytes,
                      let data = try? Data(contentsOf: item.url), let png = ClipboardAssets.png(from: data) else { return }
                DispatchQueue.main.async {
                    let pb = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
                    guard pb.changeCount == count else { return }
                    let imageEntry = NSPasteboardItem()
                    imageEntry.setString(item.url.absoluteString, forType: .fileURL)
                    imageEntry.setString("1", forType: ClipboardWatcher.ownCopyType)
                    imageEntry.setData(png, forType: .png)
                    pb.clearContents()
                    pb.writeObjects([imageEntry])
                }
            }
        }
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func copyPath(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.text == nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if NSWorkspace.shared.open(item.url) { recentFiles.record(item) }
    }

    func recordUsage(_ item: Pegged) { recentFiles.record(item) }

    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isPlaceholder else { return }
        HoverPreview.shared.close()
        if item.kind == .image { Markup.shared.edit(item.url) }
        else if item.kind == .video { Trim.shared.edit(item.url, size: item.thumb.size) }
        else { quickLook(id) }
    }

    func quickLook(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        HoverPreview.shared.close()
        QuickLook.shared.show(items.map(\.url), at: index)
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.text == nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func reloadThumbnail(for url: URL) {
        if let item = items.first(where: { $0.url == url }) { loadThumbnail(item) }
    }

    func reloadThumbnails() {
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        for item in items where !item.isPlaceholder && item.text == nil { loadThumbnail(item) }
    }

    private func loadThumbnail(_ item: Pegged) {
        let task = ThumbnailLoader.shared.load(item.url, kind: item.kind,
            pixels: Int(320 * Layout.size.scale), modified: item.modified) { [weak self] image in
                guard let self, let image else { return }
                if let i = self.items.firstIndex(where: { $0.id == item.id && $0.modified == item.modified }) {
                    self.items[i].thumb = image
                }
                if let i = self.captures.firstIndex(where: { $0.id == item.id }) { self.captures[i].thumb = image }
            }
        thumbnailTasks.append(task)
    }

    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if self.revealed, self.draggingID == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.gust += 1 }
            self.scheduleGust()
        }
    }

    private func saveCaptures() {
        let records = captures.map { ClipboardRecord(id: $0.id, url: $0.url, kind: $0.kind, text: $0.text, ownedAsset: $0.ownedAsset) }
        do { defaults.set(try JSONEncoder().encode(records), forKey: "clipboardRecords") }
        catch { recordingMessage = "无法保存剪贴板记录：\(error.localizedDescription)" }
    }

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
