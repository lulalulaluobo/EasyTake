import AppKit

struct RecentFileRecord: Codable {
    let url: URL
    let usedAt: Date
    let kind: FileKind
    var bookmark: Data?
}

/// Uses the user's home scope plus explicitly added folders, matching system LastUsedDate semantics.
@MainActor
final class RecentFiles {
    private let defaults: UserDefaults
    private(set) var records: [RecentFileRecord]
    private(set) var indexedResultCount = 0
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var accesses: [FolderAccess] = []
    private var localAccesses: [FolderAccess] = []
    private var generation = UUID()
    private var scopesFailed = false
    private var gathering = false
    private var onUpdate: (([RecentFileRecord], String?) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        records = (defaults.data(forKey: "recentFiles").flatMap { try? JSONDecoder().decode([RecentFileRecord].self, from: $0) }) ?? []
    }

    func record(_ item: Pegged, at date: Date = Date()) {
        guard !item.ownedAsset else { return }
        let entry = RecentFileRecord(url: item.url, usedAt: date, kind: item.kind)
        records = Self.merge(records, [entry], filter: nil, limit: 200)
        persist()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bookmark = try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            DispatchQueue.main.async {
                guard let self, let index = self.records.firstIndex(where: { $0.url == item.url && $0.usedAt == date }) else { return }
                self.records[index].bookmark = bookmark
                self.persist()
            }
        }
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(records), forKey: "recentFiles") }
        catch { log.error("无法保存最近访问记录：\(error.localizedDescription, privacy: .public)") }
    }

    nonisolated static func merge(_ local: [RecentFileRecord], _ system: [RecentFileRecord], filter: FileKind?, limit: Int = 20) -> [RecentFileRecord] {
        var unique: [String: RecentFileRecord] = [:]
        for record in local + system where filter == nil || record.kind == filter {
            let path = record.url.standardizedFileURL.path
            if let old = unique[path], old.usedAt >= record.usedAt { continue }
            unique[path] = record
        }
        return Array(unique.values.sorted {
            $0.usedAt == $1.usedAt ? $0.url.path < $1.url.path : $0.usedAt > $1.usedAt
        }.prefix(limit))
    }

    func start(sources: [FolderSource], systemEnabled: Bool, filter: FileKind?, onUpdate: @escaping ([RecentFileRecord], String?) -> Void) {
        stop()
        self.onUpdate = onUpdate
        gathering = systemEnabled
        onUpdate(Self.merge(records, [], filter: filter), systemEnabled ? "正在读取系统最近访问记录…" : "仅显示随取自身的使用记录。")
        let request = generation
        let localRecords = records
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var access: [FolderAccess] = []
            var localAccess: [FolderAccess] = []
            var resolved: [RecentFileRecord] = []
            for record in localRecords {
                var record = record
                if let bookmark = record.bookmark {
                    if let (url, stale) = try? FileBookmark.resolve(bookmark) {
                        localAccess.append(FolderAccess(url))
                        record = RecentFileRecord(url: url, usedAt: record.usedAt, kind: record.kind,
                            bookmark: stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : bookmark)
                    }
                }
                resolved.append(record)
            }
            for source in sources where systemEnabled {
                if let (url, _) = try? source.resolve() { access.append(FolderAccess(url)) }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.accesses = access
                self.localAccesses = localAccess
                self.records = resolved
                self.persist()
                guard systemEnabled else {
                    self.onUpdate?(Self.merge(resolved, [], filter: filter), "仅显示随取自身的使用记录。")
                    return
                }
                self.scopesFailed = access.count != sources.count
                self.startQuery(filter: filter)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == request, self.gathering else { return }
            self.onUpdate?(Self.merge(self.records, [], filter: filter), "系统最近访问查询超时；可重试，目前显示随取自身记录。")
            self.generation = UUID()
            self.stopQuery()
        }
    }

    private func startQuery(filter: FileKind?) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope] + accesses.map { $0.url.path }
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate > %@", Date(timeIntervalSince1970: 0) as NSDate)
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        query.notificationBatchingInterval = 0.5
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readResults(filter: filter) }
            })
        }
        self.query = query
        if !query.start() {
            gathering = false
            onUpdate?(Self.merge(records, [], filter: filter), "系统索引不可用，目前显示随取自身记录。")
        }
    }

    private func readResults(filter: FileKind?) {
        guard let query else { return }
        if !query.isGathering { gathering = false }
        query.disableUpdates()
        indexedResultCount = query.resultCount
        var system: [RecentFileRecord] = []
        let count = min(query.resultCount, 500)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String,
                  let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date else { continue }
            let contentType = item.value(forAttribute: "kMDItemContentType") as? String
            let url = URL(fileURLWithPath: path)
            let typeTree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
            guard contentType != "public.folder", !typeTree.contains("com.apple.application"),
                  !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { continue }
            let kind = FileKind.identify(url, isDirectory: contentType == "public.folder")
            system.append(RecentFileRecord(url: url, usedAt: date, kind: kind))
        }
        query.enableUpdates()
        let status = scopesFailed ? "部分自定义目录不可用；仍显示个人文件范围的系统记录及随取自身记录。"
            : system.isEmpty ? "系统暂无可读取的最近访问记录；可能尚未索引或受权限限制。目前显示随取自身记录。"
            : "系统最近访问可能存在索引延迟，按实际使用时间排序。"
        onUpdate?(Self.merge(records, system, filter: filter), status)
    }

    func stop() {
        generation = UUID()
        stopQuery()
        onUpdate = nil
        accesses = []
        localAccesses = []
    }

    private func stopQuery() {
        gathering = false
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
