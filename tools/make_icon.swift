// Renders the Dark Wake app icon: a ship's Kelvin wake with no ship in it.
// Usage: swift tools/make_icon.swift DarkWake/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let N = 1024
let S = CGFloat(N)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin, y down.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

// Sea: deep navy, lit faintly from around the empty spot.
ctx.setFillColor(rgb(0x02050C)); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
let sea = CGGradient(colorsSpace: cs, colors: [rgb(0x0E2A47), rgb(0x081A30), rgb(0x02050C)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawRadialGradient(sea, startCenter: CGPoint(x: S / 2, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: S / 2, y: 430), endRadius: 760, options: [.drawsAfterEndLocation])

// Everything below is drawn in the wake's own frame: the vanished ship at
// the origin, heading up-right along the diagonal, wake trailing along +y.
let apex = CGPoint(x: 670, y: 350)
let heading: CGFloat = 45 * .pi / 180
ctx.translateBy(x: apex.x, y: apex.y)
ctx.rotate(by: heading)
let origin = CGPoint.zero

// Kelvin wake: the arms sit 19.47 degrees either side of the track, whatever the speed.
let half = 19.47 * CGFloat.pi / 180
let reach: CGFloat = 1000

/// Strokes `path` with a colour that fades out with distance behind the ship.
func fadedStroke(_ path: CGPath, width: CGFloat, color: UInt32, alpha: CGFloat, fadeTo end: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(color, alpha), rgb(color, alpha * 0.5), rgb(color, 0)] as CFArray,
                       locations: [0, 0.4, 1])!
    ctx.drawLinearGradient(g, start: origin, end: CGPoint(x: 0, y: end), options: [.drawsBeforeStartLocation])
    ctx.restoreGState()
}

// Churned water down the middle, brightest just behind the ship.
let track = CGMutablePath(); track.move(to: CGPoint(x: 0, y: 30)); track.addLine(to: CGPoint(x: 0, y: 620))
fadedStroke(track, width: 110, color: 0x9FEFFF, alpha: 0.13, fadeTo: 640)
fadedStroke(track, width: 46, color: 0xDFFBFF, alpha: 0.30, fadeTo: 540)

// Faint arm lines under the crests.
let arms = CGMutablePath()
arms.move(to: CGPoint(x: -sin(half) * reach, y: cos(half) * reach)); arms.addLine(to: CGPoint(x: 0, y: 24))
arms.addLine(to: CGPoint(x: sin(half) * reach, y: cos(half) * reach))
fadedStroke(arms, width: 60, color: 0x5EF2FF, alpha: 0.20, fadeTo: 820)

// Seeded jitter so the crests look natural but the icon renders the same every time.
var seed: UInt64 = 0x5EED_DA2C
func jitter(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return lo + (hi - lo) * CGFloat(seed >> 40) / CGFloat(1 << 24)
}

/// One wave crest: a slightly bowed stroke with a soft glow under it.
func crest(from a: CGPoint, to b: CGPoint, bow: CGFloat, alpha: CGFloat, core: UInt32) {
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    let (dx, dy) = (b.x - a.x, b.y - a.y)
    let len = max(hypot(dx, dy), 1)
    let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)
    let p = CGMutablePath(); p.move(to: a); p.addQuadCurve(to: b, control: ctrl)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0x5EF2FF, 0.30 * alpha)); ctx.setLineWidth(26)
    ctx.addPath(p); ctx.strokePath()
    ctx.setStrokeColor(rgb(core, 0.97 * alpha)); ctx.setLineWidth(11)
    ctx.addPath(p); ctx.strokePath()
}

// Transverse crests: faint, close behind the ship, spanning between the arms.
for d in [CGFloat(120), 215] {
    let w = tan(half) * d * 0.8
    crest(from: CGPoint(x: -w, y: d + 6), to: CGPoint(x: w, y: d + 6), bow: -d * 0.12,
          alpha: 0.32 - d / 1400, core: 0xBFF8FF)
}

// Divergent crests: short feathers along each arm, angled back across it,
// longer and fainter with distance -- the herringbone of a real wake.
for side in [CGFloat(-1), 1] {
    var d: CGFloat = 80
    var i = 0
    while d < 980 {
        let base = CGPoint(x: side * sin(half) * d, y: cos(half) * d)
        let feather = (34 + d * 0.08) * jitter(0.8, 1.2)
        let a = half + jitter(30, 42) * .pi / 180
        let tip = CGPoint(x: base.x + side * sin(a) * feather, y: base.y + cos(a) * feather)
        let tail = CGPoint(x: base.x - side * sin(a) * feather * 0.5, y: base.y - cos(a) * feather * 0.5)
        let fade = max(0, 1 - d / 980)
        crest(from: tail, to: tip, bow: side * feather * 0.18, alpha: fade * fade * 1.1,
              core: i % 3 == 0 ? 0xE6FDFF : 0xA8F6FF)
        d += 40 + d * 0.05
        i += 1
    }
}

// Where the ship should be: nothing, ringed in red.
ctx.setFillColor(rgb(0x02050C))
ctx.fillEllipse(in: CGRect(x: -66, y: -66, width: 132, height: 132))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 44, color: rgb(0xFF4D6D, 0.95))
ctx.setStrokeColor(rgb(0xFF5F7E)); ctx.setLineWidth(20)
ctx.setLineDash(phase: 0, lengths: [42, 26])
ctx.strokeEllipse(in: CGRect(x: -90, y: -90, width: 180, height: 180))
ctx.restoreGState()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
precondition(CGImageDestinationFinalize(dest))
print("wrote \(out.path) \(img.width)x\(img.height) alpha=\(img.alphaInfo.rawValue)")
