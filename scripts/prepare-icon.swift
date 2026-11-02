// Turns a logo picture (rounded square on a black background) into a 1024px macOS
// app-icon master: crops to the square, makes the corners transparent, and sizes it
// to Apple's icon grid. Usage: swift scripts/prepare-icon.swift <in> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: prepare-icon.swift <input image> <output.png>"); exit(1)
}

// Read pixels to find where the card starts against the black backdrop.
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
func lit(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 45
}
let midY = h / 2, midX = w / 2
let left = (0..<w).first { lit($0, midY) }!
let right = (0..<w).reversed().first { lit($0, midY) }!
let bottom = (0..<h).first { lit(midX, $0) }!          // CG rows start at the bottom
let top = (0..<h).reversed().first { lit(midX, $0) }!
let card = CGRect(x: left, y: bottom, width: right - left + 1, height: top - bottom + 1)
print("card bounds:", card)

// Apple's grid: 824pt body centred in a 1024pt canvas.
let size: CGFloat = 1024, body: CGFloat = 824
let out = NSImage(size: NSSize(width: size, height: size))
out.lockFocus()
let dest = NSRect(x: (size - body) / 2, y: (size - body) / 2 + 6, width: body, height: body)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSBezierPath(roundedRect: dest, xRadius: body * 0.225, yRadius: body * 0.225).fill()
NSGraphicsContext.restoreGraphicsState()

NSBezierPath(roundedRect: dest, xRadius: body * 0.225, yRadius: body * 0.225).addClip()
// Trim a few pixels so the source's own soft edge and glow don't show.
let cropped = cg.cropping(to: CGRect(x: card.minX + 6, y: CGFloat(h) - card.maxY + 6,
                                     width: card.width - 12, height: card.height - 12))!
NSImage(cgImage: cropped, size: .zero).draw(in: dest)
out.unlockFocus()

let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
