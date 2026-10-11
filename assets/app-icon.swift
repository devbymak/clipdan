// Draw the Clipdan app icon: a clipboard holding a picture and lines of text, on a navy tile.
// Regenerate assets/app-icon.png with: xcrun swift assets/app-icon.swift assets/app-icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: 1)
}
func fill(_ rect: CGRect, radius: Double, _ hex: UInt32) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color(hex))
    context.fillPath()
}

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downwards, like the design coordinates.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// The macOS icon grid: an 824 pt tile centred on the 1024 pt canvas.
fill(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185, 0x101B32)

// The board, its sheet of paper, and the clip that holds it.
fill(CGRect(x: 287, y: 240, width: 450, height: 580), radius: 58, 0xF2A93B)
fill(CGRect(x: 327, y: 300, width: 370, height: 480), radius: 28, 0xF7F4EC)
fill(CGRect(x: 407, y: 200, width: 210, height: 96), radius: 34, 0xC77F1C)
fill(CGRect(x: 467, y: 222, width: 90, height: 30), radius: 15, 0x101B32)

// Two lines of text.
fill(CGRect(x: 371, y: 348, width: 282, height: 26), radius: 13, 0xC5CCD8)
fill(CGRect(x: 371, y: 398, width: 200, height: 26), radius: 13, 0xC5CCD8)

// The picture: sky, sun, and two hills, clipped to a rounded frame.
let picture = CGRect(x: 371, y: 460, width: 282, height: 276)
context.saveGState()
context.addPath(CGPath(roundedRect: picture, cornerWidth: 22, cornerHeight: 22, transform: nil))
context.clip()
context.setFillColor(color(0x3987E5))
context.fill(picture)
context.setFillColor(color(0xF47B42))
context.fillEllipse(in: CGRect(x: 568, y: 500, width: 56, height: 56))
func hill(_ points: [CGPoint], _ hex: UInt32) {
    context.beginPath()
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.closePath()
    context.setFillColor(color(hex))
    context.fillPath()
}
hill([CGPoint(x: 371, y: 736), CGPoint(x: 371, y: 650), CGPoint(x: 470, y: 572), CGPoint(x: 600, y: 736)], 0x1D4E9A)
hill([CGPoint(x: 500, y: 736), CGPoint(x: 590, y: 640), CGPoint(x: 653, y: 690), CGPoint(x: 653, y: 736)], 0x2A6CC8)
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
