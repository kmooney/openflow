// Draws the OpenFlow mark: a ring with a waveform inside it.
//
// Drawn rather than exported from SF Symbols on purpose. The app's toolbar uses
// `waveform.circle`, and the SF Symbols licence forbids using those symbols in
// app icons, logos, or anything else trademark-like — rasterising one into an
// AppIcon is an App Store rejection waiting to happen. This is the same mark,
// owned outright, and being vector means the weights can be tuned per size
// rather than scaled blindly down to 16pt where a thin ring disappears.
//
// Usage:  swift icon.swift <size> <out.png> [light|dark]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let size = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: icon.swift <size> <out.png> [light|dark]\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: args[2])
let dark = args.count > 3 && args[3] == "dark"

let s = CGFloat(size)
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

// Near-black rather than pure black, and off-white rather than pure white: flat
// #000 on #fff is harsher on a home screen than it looks in a design tool.
let ink   = dark ? CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
                 : CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
let ground = dark ? CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
                  : CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)

ctx.setFillColor(ground)
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

// The ring. Heavier at small sizes: a stroke that reads as a confident circle
// at 1024 is a grey smudge at 16, so the weight climbs as the canvas shrinks.
let radius = 0.355 * s
let strokeScale: CGFloat = size <= 32 ? 0.085 : (size <= 64 ? 0.072 : 0.058)
let stroke = strokeScale * s
ctx.setStrokeColor(ink)
ctx.setLineWidth(stroke)
ctx.strokeEllipse(in: CGRect(x: s / 2 - radius, y: s / 2 - radius,
                             width: radius * 2, height: radius * 2))

// The waveform: five bars, tallest in the middle, rounded caps. Five rather
// than seven because at 16pt seven bars merge into a solid block.
//
// Values are HALF-heights as a fraction of the canvas, and the tallest must
// clear the ring's inner edge (0.355 - 0.058/2 = 0.326) with room to spare —
// the first pass used full heights here, so the centre bar punched through the
// ring and reappeared as a dot above and below it.
let heights: [CGFloat] = [0.085, 0.150, 0.215, 0.150, 0.085]
let barWidth = 0.055 * s
let gap = 0.038 * s
let pitch = barWidth + gap
let totalWidth = pitch * CGFloat(heights.count - 1)
let startX = s / 2 - totalWidth / 2

ctx.setFillColor(ink)
ctx.setLineCap(.round)
ctx.setLineWidth(barWidth)
for (i, h) in heights.enumerated() {
    let x = startX + pitch * CGFloat(i)
    let half = h * s
    // Drawn as a capped line rather than a rounded rect: the cap radius then
    // follows the bar width automatically at every size.
    ctx.move(to: CGPoint(x: x, y: s / 2 - half + barWidth / 2))
    ctx.addLine(to: CGPoint(x: x, y: s / 2 + half - barWidth / 2))
    ctx.strokePath()
}
ctx.setStrokeColor(ink)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
