import AppKit
import ImageIO

struct ClipboardRecord: Codable {
    var id = UUID()
    let url: URL
    let kind: FileKind
    var text: String?
    var ownedAsset = false
}

/// Writes and removes only assets created inside Suiqu's own cache, never referenced user files.
enum ClipboardAssets {
    static let maxTextBytes = 1024 * 1024
    static let maxImageBytes = 64 * 1024 * 1024
    static let maxCacheBytes = 256 * 1024 * 1024
    static let queue = DispatchQueue(label: "local.suiqu.clipboard-assets", qos: .userInitiated)

    static func save(_ data: Data, extension suffix: String, directory: URL = Inbox.folder) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let used = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard data.count <= maxCacheBytes - used else {
            throw NSError(domain: "Suiqu", code: 1, userInfo: [NSLocalizedDescriptionKey: "剪贴板缓存达到 256 MB，请先移除部分历史。"])
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        do {
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    static func remove(_ record: ClipboardRecord, directory: URL = Inbox.folder) {
        guard record.ownedAsset,
              record.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: record.url)
    }

    static func png(from data: Data) -> Data? {
        guard data.count <= maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 80_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= maxImageBytes else { return nil }
        return result as Data
    }
}
