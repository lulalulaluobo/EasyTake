import AppKit

// Disposable local interaction samples. Does not read personal files or alter app preferences.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/suiqu-v03-qa", isDirectory: true)
let source = root.appendingPathComponent("source", isDirectory: true)
let destination = root.appendingPathComponent("destination", isDirectory: true)
try FileManager.default.createDirectory(at: source.appendingPathComponent("子文件夹"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try "随取验收文本：原件应保留，复制内容应一致。\n第二行文本。".write(to: source.appendingPathComponent("示例文本.txt"), atomically: true, encoding: .utf8)
try "子目录文件不应出现在挂绳根目录中。".write(to: source.appendingPathComponent("子文件夹/内层.txt"), atomically: true, encoding: .utf8)
try Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: source.appendingPathComponent("空压缩包.zip"))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1100, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0.85, green: 0.94, blue: 1, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1800, height: 1100).fill()
let message = NSAttributedString(string: "随取 · 清晰预览\n1800 × 1100 原始像素", attributes: [
    .font: NSFont.systemFont(ofSize: 70, weight: .semibold), .foregroundColor: NSColor.darkGray,
])
message.draw(in: NSRect(x: 120, y: 500, width: 1600, height: 250))
NSColor.systemOrange.setFill()
for index in 0..<12 { NSRect(x: 120 + index * 125, y: 200, width: 60, height: 120).fill() }
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: source.appendingPathComponent("清晰预览.png"))
print(root.path)
