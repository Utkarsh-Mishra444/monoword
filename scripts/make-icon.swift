// Draws Monoword's 1024 px app icon: the reader itself, one word between two guide lines and a
// progress bar. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Body on the macOS icon grid: 824 px square, 185 px corner radius, centred.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
           ending: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1))!.draw(in: shape, angle: -90)

let red = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.31, alpha: 1)
let guide = NSColor(white: 1, alpha: 0.22)
let top: CGFloat = 690, bottom: CGFloat = 334

// Two guide lines; along the lower one, a progress bar a third of the way through.
guide.setFill()
NSRect(x: 190, y: top, width: 644, height: 7).fill()
NSRect(x: 190, y: bottom - 7, width: 644, height: 7).fill()
red.setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: bottom - 9, width: 230, height: 11), xRadius: 5.5, yRadius: 5.5).fill()

// One word, centred.
let font = NSFont.systemFont(ofSize: 250, weight: .semibold)
let word = NSAttributedString(string: "word", attributes: [.font: font, .foregroundColor: NSColor(white: 0.96, alpha: 1)])
let line = CTLineCreateWithAttributedString(word)
let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
let baseline = (top + bottom) / 2 - font.capHeight / 2
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: (size - width) / 2, y: baseline)
    CTLineDraw(line, ctx)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
