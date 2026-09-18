import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Design/AppIcon/signal-source.png")
guard let input = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
    fatalError("Missing icon master: \(sourceURL.path)")
}
var images: [[String: String]] = []
func render(_ pixels: Int, _ filename: String, iOS: Bool = false) {
    let alpha: CGImageAlphaInfo = iOS ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    context.interpolationQuality = .high
    let destination = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    var artwork = source
    if iOS {
        // iOS supplies its own corner mask. Remove the preview margin and fill transparencies.
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
        context.fill(destination)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        artwork = source.cropping(to: bounds.insetBy(dx: bounds.width * 0.11, dy: bounds.height * 0.11))!
    }
    context.draw(artwork, in: destination)
    let output = CGImageDestinationCreateWithURL(root.appendingPathComponent(filename) as CFURL,
        UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output), "Could not export \(filename)")
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(size)@\(scale)x.png"
        render(size * scale, filename)
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
render(1024, "universal.png", iOS: true)
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "universal.png"])
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("Contents.json"))
