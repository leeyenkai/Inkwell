// Draws the original illustration used by the README's sample draft: hills at dusk.
import AppKit

let size = NSSize(width: 1600, height: 1000)
let image = NSImage(size: size, flipped: false) { rect in
    NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.42, green: 0.36, blue: 0.75, alpha: 1),
                        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.32, alpha: 1)])!.draw(in: rect, angle: 90)
    NSColor(srgbRed: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 1020, y: 380, width: 190, height: 190)).fill()
    let layers: [(CGFloat, NSColor)] = [(430, NSColor(srgbRed: 0.30, green: 0.27, blue: 0.55, alpha: 1)),
                                        (300, NSColor(srgbRed: 0.20, green: 0.19, blue: 0.42, alpha: 1)),
                                        (170, NSColor(srgbRed: 0.11, green: 0.11, blue: 0.26, alpha: 1))]
    for (i, (height, color)) in layers.enumerated() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 0, y: height))
        var x: CGFloat = 0
        while x <= size.width {
            let y = height + 70 * sin((x / size.width) * .pi * CGFloat(2 + i) + CGFloat(i))
            path.line(to: NSPoint(x: x, y: y))
            x += 20
        }
        path.line(to: NSPoint(x: size.width, y: 0))
        path.close()
        color.setFill()
        path.fill()
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
