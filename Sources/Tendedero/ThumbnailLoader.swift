import AppKit
import AVFoundation
import ImageIO

/// Shared bounded work queue. Preview pixels have a separate cache key from card pixels.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()

    @discardableResult
    func load(_ url: URL, kind: FileKind, pixels: Int, modified: Date? = nil,
              completion: @escaping (NSImage?) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, self] in
            guard operation?.isCancelled == false else { return }
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .contentModificationDateKey])
            let date = modified ?? values?.contentModificationDate
            let key = "\(url.path)|\(pixels)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
            let image: NSImage?
            if let cached = cache.object(forKey: key) { image = cached }
            else {
                if values?.ubiquitousItemDownloadingStatus == .notDownloaded { image = nil }
                else if kind == .image || kind == .video { image = makeThumbnail(url, maxPixels: pixels) }
                else { image = NSWorkspace.shared.icon(forFile: url.path) }
                if let image {
                    cache.setObject(image, forKey: key, cost: pixels * pixels * 4)
                }
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [operation] in if operation?.isCancelled == false { completion(image) } }
        }
        queue.addOperation(operation)
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
