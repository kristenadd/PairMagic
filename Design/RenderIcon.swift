// Renders the PairMagic logo: two interlocking links with sparkles on a
// violet-to-blue macOS-style squircle.
//
//   swift Design/RenderIcon.swift <output.png> [size]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "icon.png"
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let scale = CGFloat(size) / 1024

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
ctx.setShouldAntialias(true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: Squircle background (Apple's macOS icon grid: 824pt tile, 100pt margin)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x5B4BFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(colorsSpace: space,
                            colors: [color(0x8A5CFF), color(0x5B6BFF), color(0x2D9CFF)] as CFArray,
                            locations: [0, 0.5, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// Soft top highlight for depth.
let highlight = CGGradient(colorsSpace: space,
                           colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
ctx.drawRadialGradient(highlight, startCenter: CGPoint(x: 380, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 380, y: 860), endRadius: 620, options: [])
ctx.restoreGState()

// MARK: Interlocking links along the top-left → bottom-right diagonal

let center = CGPoint(x: 512, y: 512)
let linkLength: CGFloat = 330
let linkWidth: CGFloat = 176
let stroke: CGFloat = 54
let offset: CGFloat = 112   // each link's distance from the center along the axis

func linkPath(at distance: CGFloat) -> CGPath {
    let rect = CGRect(x: -linkLength / 2 + distance, y: -linkWidth / 2, width: linkLength, height: linkWidth)
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -.pi / 4)
    return CGPath(roundedRect: rect, cornerWidth: linkWidth / 2, cornerHeight: linkWidth / 2, transform: &transform)
}

let linkA = linkPath(at: -offset)
let linkB = linkPath(at: offset)

func drawLink(_ path: CGPath, width: CGFloat = stroke, color strokeColor: CGColor = color(0xFFFFFF)) {
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(strokeColor)
    ctx.strokePath()
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1A0F66, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
drawLink(linkA)
drawLink(linkB)
ctx.endTransparencyLayer()
ctx.restoreGState()

// The links' end caps cross at two points either side of the axis. At each,
// redraw one link on top, shading the link underneath next to it, so they
// weave over and under.
let capOffset = offset - linkLength / 2 + linkWidth / 2          // cap centers at ±capOffset
let crossing = sqrt(pow(linkWidth / 2, 2) - pow(capOffset, 2))   // crossings at (0, ±crossing)
let toAxis = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -.pi / 4)
for (side, top, under) in [(CGFloat(1), linkA, linkB), (CGFloat(-1), linkB, linkA)] {
    let point = CGPoint(x: 0, y: side * crossing).applying(toAxis)
    let area = CGRect(x: point.x - 110, y: point.y - 110, width: 220, height: 220)
    ctx.saveGState()
    ctx.addEllipse(in: area)
    ctx.clip()
    ctx.addPath(under.copy(strokingWithWidth: stroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    ctx.clip()
    drawLink(top, width: stroke + 26, color: color(0x3A2DB8, 0.45))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: area)
    ctx.clip()
    drawLink(top)
    ctx.restoreGState()
}

// MARK: Sparkles

func sparkle(at point: CGPoint, radius: CGFloat, alpha: CGFloat = 1) {
    let path = CGMutablePath()
    let pinch = radius * 0.16
    path.move(to: CGPoint(x: point.x, y: point.y + radius))
    path.addQuadCurve(to: CGPoint(x: point.x + radius, y: point.y), control: CGPoint(x: point.x + pinch, y: point.y + pinch))
    path.addQuadCurve(to: CGPoint(x: point.x, y: point.y - radius), control: CGPoint(x: point.x + pinch, y: point.y - pinch))
    path.addQuadCurve(to: CGPoint(x: point.x - radius, y: point.y), control: CGPoint(x: point.x - pinch, y: point.y - pinch))
    path.addQuadCurve(to: CGPoint(x: point.x, y: point.y + radius), control: CGPoint(x: point.x - pinch, y: point.y + pinch))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: radius * 0.5, color: color(0xFFFFFF, 0.6 * alpha))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFFFFF, alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

sparkle(at: CGPoint(x: 712, y: 724), radius: 92)
sparkle(at: CGPoint(x: 806, y: 616), radius: 42, alpha: 0.9)
sparkle(at: CGPoint(x: 300, y: 312), radius: 58, alpha: 0.85)

// MARK: Write

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(size)px)")
