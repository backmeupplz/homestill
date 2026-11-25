// Draws Roomwell/Assets.xcassets/AppIcon.appiconset/icon.png: swift ios/icon.swift ios/Roomwell/Assets.xcassets/AppIcon.appiconset/icon.png
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
let n = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.setFillColor(CGColor(srgbRed: 0.12, green: 0.55, blue: 0.53, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
// house: rounded roof triangle + body, y axis up
let p = CGMutablePath()
p.move(to: CGPoint(x: 512, y: 800))           // roof peak
p.addLine(to: CGPoint(x: 820, y: 530))
p.addLine(to: CGPoint(x: 740, y: 530))
p.addLine(to: CGPoint(x: 740, y: 250))
p.addLine(to: CGPoint(x: 284, y: 250))
p.addLine(to: CGPoint(x: 284, y: 530))
p.addLine(to: CGPoint(x: 204, y: 530))
p.closeSubpath()
c.addPath(p); c.setLineJoin(.round); c.setLineWidth(70)
c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
c.drawPath(using: .fillStroke)
// door
let door = CGPath(roundedRect: CGRect(x: 452, y: 215, width: 120, height: 190), cornerWidth: 40, cornerHeight: 40, transform: nil)
c.addPath(door); c.setFillColor(CGColor(srgbRed: 0.12, green: 0.55, blue: 0.53, alpha: 1)); c.fillPath()
c.fill(CGRect(x: 452, y: 215, width: 120, height: 60))
let img = c.makeImage()!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
