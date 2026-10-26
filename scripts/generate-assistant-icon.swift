// Original geometric artwork for Interface Cable Assistant. MIT licensed.
import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16,"icon_16x16.png"),(32,"icon_16x16@2x.png"),(32,"icon_32x32.png"),(64,"icon_32x32@2x.png"),(128,"icon_128x128.png"),(256,"icon_128x128@2x.png"),(256,"icon_256x256.png"),(512,"icon_256x256@2x.png"),(512,"icon_512x512.png"),(1024,"icon_512x512@2x.png")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSAffineTransform().withScale(scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 55,y: 55,width: 914,height: 914), xRadius: 205,yRadius: 205)
    NSColor(calibratedRed: 0.07,green: 0.15,blue: 0.22,alpha: 1).setFill(); background.fill()
    let cable = NSBezierPath(); cable.move(to: NSPoint(x: 367,y: 545))
    cable.curve(to: NSPoint(x: 759,y: 540), controlPoint1: NSPoint(x: 367,y: 175), controlPoint2: NSPoint(x: 759,y: 175))
    cable.lineWidth = 75; cable.lineCapStyle = .round
    NSColor(calibratedRed: 1,green: 0.63,blue: 0.27,alpha: 1).setStroke(); cable.stroke()
    NSColor(calibratedRed: 0.2,green: 0.84,blue: 0.83,alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 175,y: 515,width: 385,height: 230), xRadius: 65,yRadius: 65).fill()
    NSColor(calibratedRed: 0.07,green: 0.15,blue: 0.22,alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 221,y: 575,width: 293,height: 110), xRadius: 40,yRadius: 40).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 686,y: 515,width: 146,height: 238), xRadius: 35,yRadius: 35).fill()
    NSColor(calibratedRed: 1,green: 0.63,blue: 0.27,alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 711,y: 753,width: 30,height: 60)).fill()
    NSBezierPath(rect: NSRect(x: 777,y: 753,width: 30,height: 60)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
extension NSAffineTransform {
    func withScale(_ value: CGFloat) { scale(by: value); concat() }
}
