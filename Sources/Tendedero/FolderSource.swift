import Foundation
import UniformTypeIdentifiers

struct FolderSource: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bookmark: Data
    var path: String
    // Codable ignores the legacy "sort" field; all sources now use Date Added.
    init(url: URL, id: UUID = UUID()) throws {
        self.id = id
        self.name = url.lastPathComponent
        self.path = url.standardizedFileURL.path
        self.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve() throws -> (URL, Bool) {
        try FileBookmark.resolve(bookmark)
    }
}

enum FileBookmark {
    static func resolve(_ data: Data) throws -> (URL, Bool) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        } catch {
            // Compatibility for older bookmarks with an embedded security scope. New bookmarks use
            // ordinary file references, as the non-sandboxed FilePanel implementation does.
            stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        }
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
    let added: Date?
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

    static func precedes(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        let lhs = a.added
        let rhs = b.added
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .addedToDirectoryDateKey,
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
                modified: values.contentModificationDate, added: values.addedToDirectoryDate,
                isPlaceholder: values.ubiquitousItemDownloadingStatus == .notDownloaded)
            if let filter, entry.kind != filter { continue }
            candidates.append(entry)
            candidates.sort(by: precedes)
            if candidates.count > candidateLimit { candidates.removeLast() }
        }
        if let scanError { throw scanError }
        let refreshed = stale ? try FolderSource(url: url, id: source.id) : nil
        let descriptor = open(url.path, O_EVTONLY)
        return FolderSnapshot(entries: candidates, scannedCount: count, limited: limited, access: access,
                              refreshedSource: refreshed, descriptor: descriptor)
    }
}
