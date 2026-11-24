// Lays out icon renders as a contact sheet: each tile on the background its appearance is meant for, plus small sizes.
// usage: swift contact.swift <out.png> <render dir>
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let dir = URL(fileURLWithPath: args[2])
let tiles: [(String, String, NSColor)] = [
    ("Default", "Default", NSColor(white: 0.93, alpha: 1)),
    ("Dark", "Dark", NSColor(white: 0.12, alpha: 1)),
    ("Clear (light)", "ClearLight", NSColor(srgbRed: 0.55, green: 0.70, blue: 0.86, alpha: 1)),
    ("Clear (dark)", "ClearDark", NSColor(srgbRed: 0.10, green: 0.14, blue: 0.24, alpha: 1)),
    ("Tinted (light)", "TintedLight", NSColor(white: 0.93, alpha: 1)),
    ("Tinted (dark)", "TintedDark", NSColor(white: 0.12, alpha: 1)),
]
let tile: CGFloat = 300, pad: CGFloat = 24, label: CGFloat = 28
let smallRow: CGFloat = 110
let size = NSSize(width: CGFloat(tiles.count) * (tile + pad) + pad, height: tile + label + pad * 2 + smallRow)
let image = NSImage(size: size, flipped: true) { _ in
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    for (i, (title, rendition, bg)) in tiles.enumerated() {
        let x = pad + CGFloat(i) * (tile + pad)
        let box = NSRect(x: x, y: pad, width: tile, height: tile)
        bg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 18, yRadius: 18).fill()
        if let icon = NSImage(contentsOf: dir.appending(path: "\(rendition).png")) {
            icon.draw(in: box.insetBy(dx: 14, dy: 14))
        }
        (title as NSString).draw(at: NSPoint(x: x + 4, y: pad + tile + 6), withAttributes: attrs)
    }
    if let icon = NSImage(contentsOf: dir.appending(path: "Default.png")) {
        var x = pad
        for side in [16, 32, 64] as [CGFloat] {
            for bg in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.12, alpha: 1)] {
                let box = NSRect(x: x, y: pad + tile + label + 18, width: 76, height: 76)
                bg.setFill()
                NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
                icon.draw(in: NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side))
                x += 86
            }
            ("\(Int(side)) px" as NSString).draw(at: NSPoint(x: x - 150, y: pad + tile + label + 98), withAttributes: attrs)
            x += 16
        }
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: out)
