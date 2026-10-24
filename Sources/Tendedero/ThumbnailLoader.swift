import AppKit
import AVFoundation
import ImageIO

/// Shared bounded work queue. Preview pixels have a separate cache key from card pixels.
final class ThumbnailLoader: @unchecked Sendable {
    enum Purpose { case card, preview }
    static let shared = ThumbnailLoader()
    private let cardQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    // Reserve one of the three decoder slots so queued cards cannot block an active hover.
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let generate: (URL, FileKind, Int) -> NSImage?
    private let latestKeys: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 100
        return cache
    }()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()

    init(generate: @escaping (URL, FileKind, Int) -> NSImage? = { url, kind, pixels in
        kind == .image || kind == .video ? makeThumbnail(url, maxPixels: pixels) : NSWorkspace.shared.icon(forFile: url.path)
    }) { self.generate = generate }

    func cachedImage(_ url: URL, pixels: Int, modified: Date? = nil) -> NSImage? {
        let base = "\(url.path)|\(pixels)" as NSString
        let key = modified.map { "\(base)|\($0.timeIntervalSince1970)" as NSString } ?? latestKeys.object(forKey: base)
        return key.flatMap { cache.object(forKey: $0) }
    }

    @discardableResult
    func load(_ url: URL, kind: FileKind, pixels: Int, modified: Date? = nil, purpose: Purpose = .card,
              completion: @escaping (NSImage?) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.queuePriority = purpose == .preview ? .veryHigh : .normal
        operation.addExecutionBlock { [weak operation, self] in
            guard operation?.isCancelled == false else { return }
            var readingURL = url
            readingURL.removeAllCachedResourceValues()
            let values = try? readingURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .contentModificationDateKey])
            let date = values?.contentModificationDate ?? modified
            let base = "\(url.path)|\(pixels)" as NSString
            let key = "\(base)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
            let image: NSImage?
            if let cached = cache.object(forKey: key) { image = cached }
            else {
                if values?.ubiquitousItemDownloadingStatus == .notDownloaded { image = nil }
                else { image = generate(url, kind, pixels) }
                if let image {
                    cache.setObject(image, forKey: key, cost: pixels * pixels * 4)
                    latestKeys.setObject(key, forKey: base)
                }
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [operation] in if operation?.isCancelled == false { completion(image) } }
        }
        (purpose == .preview ? previewQueue : cardQueue).addOperation(operation)
        return operation
    }
}

func isRecording(_ url: URL) -> Bool { FileKind.identify(url) == .video }

func makeThumbnail(_ url: URL, maxPixels: Int = 640) -> NSImage? {
    if isRecording(url) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
