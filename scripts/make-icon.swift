import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [[String:String]] = []
func render(_ pixels: Int, _ filename: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0,y: 0,width: 1024,height: 1024)).fill()
    NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 1).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 228, y: 254, width: 548, height: 548)); ring.lineWidth = 100; ring.stroke()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 600,y: 400)); tail.line(to: NSPoint(x: 799,y: 206)); tail.lineWidth = 100; tail.lineCapStyle = .round; tail.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(filename))
}
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let filename = "mac-\(size)@\(scale)x.png"
        render(size*scale, filename)
        images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":filename])
    }
}
render(1024, "universal.png")
images.append(["idiom":"universal", "platform":"ios", "size":"1024x1024", "filename":"universal.png"])
let contents: [String:Any] = ["images":images,"info":["author":"xcode","version":1]]
try! JSONSerialization.data(withJSONObject: contents, options:.prettyPrinted).write(to: root.appendingPathComponent("Contents.json"))
