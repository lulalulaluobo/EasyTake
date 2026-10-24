// Original Suiqu mark: orange lightning on a folded file. No upstream brand assets.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Suiqu.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 1, green: 0.66, blue: 0.25, alpha: 1),
           ending: NSColor(srgbRed: 0.97, green: 0.33, blue: 0.10, alpha: 1))!.draw(in: body, angle: -90)
let file = NSBezierPath()
file.move(to: NSPoint(x: 310, y: 230))
file.line(to: NSPoint(x: 714, y: 230))
file.line(to: NSPoint(x: 714, y: 650))
file.line(to: NSPoint(x: 574, y: 790))
file.line(to: NSPoint(x: 310, y: 790))
file.close()
NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1).setFill()
file.fill()
let fold = NSBezierPath()
fold.move(to: NSPoint(x: 574, y: 790)); fold.line(to: NSPoint(x: 574, y: 650))
fold.line(to: NSPoint(x: 714, y: 650)); fold.close()
NSColor(srgbRed: 1, green: 0.81, blue: 0.59, alpha: 1).setFill(); fold.fill()
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 548, y: 677)); bolt.line(to: NSPoint(x: 393, y: 455))
bolt.line(to: NSPoint(x: 496, y: 455)); bolt.line(to: NSPoint(x: 455, y: 312))
bolt.line(to: NSPoint(x: 638, y: 545)); bolt.line(to: NSPoint(x: 533, y: 545)); bolt.close()
NSColor(srgbRed: 0.98, green: 0.39, blue: 0.12, alpha: 1).setFill(); bolt.fill()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
