import Foundation
import UniformTypeIdentifiers

enum FolderSort: String, Codable, CaseIterable {
    case modified, created
    var title: String { self == .modified ? "最近修改" : "最近新建" }
}

struct FolderSource: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bookmark: Data
    var path: String
    var sort: FolderSort = .modified

    init(url: URL, id: UUID = UUID(), sort: FolderSort = .modified) throws {
        self.id = id
        self.name = url.lastPathComponent
        self.path = url.standardizedFileURL.path
        self.sort = sort
        self.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve() throws -> (URL, Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

enum FileKind: String, Codable, CaseIterable {
    case image, video, text, file, folder
    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .text: return "文本"
        case .file: return "文件"
        case .folder: return "文件夹"
        }
    }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .text: return "doc.text"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
    static func identify(_ url: URL, isDirectory: Bool = false) -> FileKind {
        if isDirectory { return .folder }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .text) { return .text }
        return .file
    }
}

struct FolderEntry {
    let url: URL
    let kind: FileKind
    let modified: Date?
    let created: Date?
    let isPlaceholder: Bool
}

/// Cancels metadata work between filesystem calls; a stalled volume never blocks the main thread.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class FolderAccess {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct FolderSnapshot {
    let entries: [FolderEntry]
    let scannedCount: Int
    let limited: Bool
    let access: FolderAccess
    let refreshedSource: FolderSource?
    let descriptor: Int32
}

enum FolderScanner {
    static let candidateLimit = 20
    // Provisional bound; measured samples and remaining performance checks are recorded in docs.
    static let scanLimit = 10_000
    static let timeLimit: TimeInterval = 3

    static func precedes(_ a: FolderEntry, _ b: FolderEntry, sort: FolderSort) -> Bool {
        let lhs = sort == .modified ? a.modified : a.created
        let rhs = sort == .modified ? b.modified : b.created
        if lhs != rhs {
            guard let lhs else { return false }
            guard let rhs else { return true }
            return lhs > rhs
        }
        return a.url.lastPathComponent < b.url.lastPathComponent
    }

    static func scan(_ source: FolderSource, cancellation: ScanCancellation, filter: FileKind? = nil) throws -> FolderSnapshot {
        if cancellation.isCancelled { throw CancellationError() }
        let (url, stale) = try source.resolve()
        let access = FolderAccess(url)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey,
                                       .ubiquitousItemDownloadingStatusKey]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, error in scanError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let started = Date()
        var candidates: [FolderEntry] = []
        var count = 0
        var limited = false
        while let file = enumerator.nextObject() as? URL {
            if cancellation.isCancelled { throw CancellationError() }
            if count >= scanLimit || Date().timeIntervalSince(started) > timeLimit { limited = true; break }
            count += 1
            let values = try file.resourceValues(forKeys: keys)
            let entry = FolderEntry(url: file, kind: FileKind.identify(file, isDirectory: values.isDirectory == true),
                modified: values.contentModificationDate, created: values.creationDate,
                isPlaceholder: values.ubiquitousItemDownloadingStatus == .notDownloaded)
            if let filter, entry.kind != filter { continue }
            candidates.append(entry)
            candidates.sort { precedes($0, $1, sort: source.sort) }
            if candidates.count > candidateLimit { candidates.removeLast() }
        }
        if let scanError { throw scanError }
        let refreshed = stale ? try FolderSource(url: url, id: source.id, sort: source.sort) : nil
        let descriptor = open(url.path, O_EVTONLY)
        return FolderSnapshot(entries: candidates, scannedCount: count, limited: limited, access: access,
                              refreshedSource: refreshed, descriptor: descriptor)
    }
}
