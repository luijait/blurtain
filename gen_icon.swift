import AppKit

// Renders the Blurtain app icon: redacted lines of "text" in Catppuccin
// Mocha colors on a dark rounded square. Output: assets/icon.png (1024x1024).

let S: CGFloat = 1024
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

// Rounded-square background with a subtle vertical gradient.
let inset: CGFloat = 76
let bgRect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 196, cornerHeight: 196, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: nil,
                      colors: [rgba(0x24273a), rgba(0x181825)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S / 2, y: S - inset),
                       end: CGPoint(x: S / 2, y: inset), options: [])
ctx.restoreGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(rgba(0x313244, 0.9))
ctx.setLineWidth(6)
ctx.strokePath()

// Censorship bars laid out like terminal lines (prompt, command, output…).
struct Bar { let w: CGFloat; let c: UInt32 }
let lines: [[Bar]] = [
    [Bar(w: 120, c: 0xa6e3a1), Bar(w: 330, c: 0xcba6f7)],
    [Bar(w: 500, c: 0x89b4fa)],
    [Bar(w: 260, c: 0xfab387), Bar(w: 180, c: 0xf38ba8)],
    [Bar(w: 420, c: 0xa6e3a1)],
    [Bar(w: 200, c: 0xf9e2af), Bar(w: 90, c: 0xcdd6f4)],
]
let barH: CGFloat = 64
let gapY: CGFloat = 42
let gapX: CGFloat = 36
let leftX: CGFloat = 214
let totalH = CGFloat(lines.count) * barH + CGFloat(lines.count - 1) * gapY
var y = (S + totalH) / 2 - barH
for line in lines {
    var x = leftX
    for b in line {
        let r = CGRect(x: x, y: y, width: b.w, height: barH)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
        ctx.setFillColor(rgba(b.c))
        ctx.fillPath()
        x += b.w + gapX
    }
    y -= barH + gapY
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let out = URL(fileURLWithPath: "assets/icon.png")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
