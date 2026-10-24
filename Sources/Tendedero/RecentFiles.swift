import AppKit

struct RecentFileRecord: Codable {
    let url: URL
    let usedAt: Date
    let kind: FileKind
    var bookmark: Data?
}

/// System results are restricted to explicitly added folder scopes and use LastUsedDate only.
@MainActor
final class RecentFiles {
    private let defaults: UserDefaults
    private(set) var records: [RecentFileRecord]
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var accesses: [FolderAccess] = []
    private var generation = UUID()
    private var scopesFailed = false
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
            let bookmark = try? item.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
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
        onUpdate(Self.merge(records, [], filter: filter), systemEnabled ? "正在查询已授权目录的系统最近访问记录…" : "仅显示随取自身的使用记录。")
        guard systemEnabled else { return }
        guard !sources.isEmpty else {
            onUpdate(Self.merge(records, [], filter: filter), "尚无已授权目录；添加文件夹来源后可查询其系统最近访问记录。目前显示随取自身记录。")
            return
        }
        let request = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var access: [FolderAccess] = []
            for source in sources {
                if let (url, _) = try? source.resolve() { access.append(FolderAccess(url)) }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.accesses = access
                self.scopesFailed = access.count != sources.count
                self.startQuery(filter: filter)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == request, self.query?.isGathering != false else { return }
            self.onUpdate?(Self.merge(self.records, [], filter: filter), "系统最近访问查询超时；可重试，目前显示随取自身记录。")
            self.stopQuery()
        }
    }

    private func startQuery(filter: FileKind?) {
        guard !accesses.isEmpty else {
            onUpdate?(Self.merge(records, [], filter: filter), "已授权目录暂不可用；可重新授权，目前显示随取自身记录。")
            return
        }
        let query = NSMetadataQuery()
        query.searchScopes = accesses.map { $0.url.path }
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
            onUpdate?(Self.merge(records, [], filter: filter), "系统索引不可用，目前显示随取自身记录。")
        }
    }

    private func readResults(filter: FileKind?) {
        guard let query else { return }
        query.disableUpdates()
        var system: [RecentFileRecord] = []
        let count = min(query.resultCount, 500)
        for index in 0..<count {
            guard let path = query.value(ofAttribute: "kMDItemPath", forResultAt: index) as? String,
                  let date = query.value(ofAttribute: "kMDItemLastUsedDate", forResultAt: index) as? Date else { continue }
            let contentType = query.value(ofAttribute: "kMDItemContentType", forResultAt: index) as? String
            let url = URL(fileURLWithPath: path)
            let kind = FileKind.identify(url, isDirectory: contentType == "public.folder")
            system.append(RecentFileRecord(url: url, usedAt: date, kind: kind))
        }
        query.enableUpdates()
        let status = scopesFailed ? "部分目录不可用；显示可读取的系统记录及随取自身记录。"
            : system.isEmpty ? "已授权目录暂无系统最近访问结果；可能尚未索引，目前显示随取自身记录。"
            : "系统记录仅限已授权目录，可能存在索引延迟。"
        onUpdate?(Self.merge(records, system, filter: filter), status)
    }

    func stop() {
        generation = UUID()
        stopQuery()
        onUpdate = nil
        accesses = []
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
