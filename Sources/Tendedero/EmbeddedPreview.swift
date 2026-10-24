import AppKit
import AVKit
import Combine
import SwiftUI

/// AppKit owns text scrolling and AVKit owns playback. No QLPreviewView teardown inside SwiftUI.
struct EmbeddedPreview: View {
    let url: URL
    var text: String = ""
    var autostarts = false

    var body: some View {
        if autostarts { NativeVideoPreview(url: url) }
        else { NativeTextPreview(text: text) }
    }
}

private struct NativeTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        let document = NSTextView(frame: .zero)
        document.isEditable = false
        document.isSelectable = true
        document.isRichText = false
        document.isHorizontallyResizable = false
        document.isVerticallyResizable = true
        document.autoresizingMask = [.width]
        document.textContainer?.widthTracksTextView = true
        document.textContainerInset = NSSize(width: 10, height: 10)
        document.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        document.textColor = .labelColor
        document.backgroundColor = .textBackgroundColor
        view.documentView = document
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let document = view.documentView as? NSTextView else { return }
        if document.string != text { document.string = text }
    }
}

private struct NativeVideoPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.player?.pause()
        view.player = AVPlayer(url: url)
        view.player?.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
        coordinator.url = nil
    }
}

struct PreviewText {
    static let maxBytes = 4 * 1024 * 1024
    let content: String
    let truncated: Bool

    static func read(_ url: URL) throws -> PreviewText {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let truncated = bytes.count > maxBytes
        let data = Data(bytes.prefix(maxBytes))
        if url.pathExtension.lowercased() == "rtf" {
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return PreviewText(content: attributed.string, truncated: truncated)
        }
        if data.isEmpty { return PreviewText(content: "", truncated: false) }
        if let text = String(data: data, encoding: .utf8) { return PreviewText(content: text, truncated: truncated) }
        if truncated {
            for count in 1...3 {
                if let text = String(data: data.dropLast(count), encoding: .utf8) { return PreviewText(content: text, truncated: true) }
            }
        }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let text = String(data: data, encoding: .utf16) { return PreviewText(content: text, truncated: truncated) }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published private(set) var ready = false
    @Published private(set) var message: String? = "正在读取预览…"
    @Published var playing = false
    @Published private(set) var text = ""
    private var task: Operation?
    private var cancelled = false

    func load(_ item: Pegged, pixels: Int) {
        let url = item.url
        // A cached full-sized preview is usable immediately; metadata validation continues off main.
        if item.kind == .image || item.kind == .video {
            image = ThumbnailLoader.shared.cachedImage(url, pixels: pixels, modified: item.modified)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> (Bool, PreviewText?) in
                let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                guard values.ubiquitousItemDownloadingStatus != .notDownloaded else { return (false, nil) }
                return (true, item.kind == .text && item.text == nil ? try PreviewText.read(url) : nil)
            }
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                switch result {
                case .success((true, let text)):
                    self.ready = true
                    self.text = text?.content ?? ""
                    self.message = text?.truncated == true ? "仅显示前 4 MB，可用快速查看阅读完整文件。" : nil
                    if item.kind == .image || item.kind == .video {
                        self.task = ThumbnailLoader.shared.load(item.url, kind: item.kind, pixels: pixels, modified: item.modified, purpose: .preview) { [weak self] image in
                            guard let self, !self.cancelled else { return }
                            self.image = image
                            if image == nil { self.message = "暂无静态预览，可使用快速查看。" }
                        }
                    }
                case .success((false, _)): self.message = "文件尚未下载，请在访达中下载后预览。"
                case .failure(let error): self.message = "文件暂不可用：\(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() { cancelled = true; playing = false; task?.cancel(); task = nil; image = nil }
}
