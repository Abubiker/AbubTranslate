import AppKit

// Генератор иконок AbubTranslate: app icon (фиолет→синий, буквы А/A + стрелка)
// и template-иконка для статус-бара.
// Запуск: swift Tools/GenerateIcons.swift

let root = "Sources/Assets.xcassets"
let appIconDir = "\(root)/AppIcon.appiconset"
let statusIconDir = "\(root)/StatusIcon.imageset"

func drawDoubleArrow(in rect: NSRect, lineWidth: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    let from = NSPoint(x: rect.minX, y: rect.minY)
    let to = NSPoint(x: rect.maxX, y: rect.maxY)
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()

    let head = lineWidth * 3.2
    let dx = to.x - from.x
    let dy = to.y - from.y
    let angle = atan2(dy, dx)

    func arrowhead(at p: NSPoint, direction: CGFloat) {
        let a1 = direction + .pi * 0.82
        let a2 = direction - .pi * 0.82
        ctx.move(to: p)
        ctx.addLine(to: NSPoint(x: p.x + cos(a1) * head, y: p.y + sin(a1) * head))
        ctx.move(to: p)
        ctx.addLine(to: NSPoint(x: p.x + cos(a2) * head, y: p.y + sin(a2) * head))
        ctx.strokePath()
    }
    arrowhead(at: to, direction: angle)
    arrowhead(at: from, direction: angle + .pi)
    ctx.restoreGState()
}

func drawAppIcon(_ s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let body = NSBezierPath(
        roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02),
        xRadius: s * 0.23,
        yRadius: s * 0.23
    )

    // Градиент фиолет → синий по диагонали.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.482, green: 0.361, blue: 1.000, alpha: 1),
        NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -55)

    // Мягкая подсветка сверху.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: body, angle: 90)

    // Буквы A (латиница) и Я (кириллица) с тенью.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.02

    let letterAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.38, weight: .heavy),
        .foregroundColor: NSColor.white,
        .shadow: shadow,
    ]
    NSAttributedString(string: "A", attributes: letterAttrs)
        .draw(at: NSPoint(x: s * 0.135, y: s * 0.475))
    NSAttributedString(string: "Я", attributes: letterAttrs)
        .draw(at: NSPoint(x: s * 0.545, y: s * 0.085))

    // Стрелка ⇄ между буквами, повёрнутая по диагонали.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: s * 0.5, y: s * 0.5)
    ctx.rotate(by: -.pi / 4)
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.34, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        .shadow: shadow,
    ]
    let arrow = NSAttributedString(string: "⇄", attributes: arrowAttrs)
    arrow.draw(at: NSPoint(x: -arrow.size().width / 2, y: -arrow.size().height * 0.55))
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func drawStatusIcon(_ s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let color = NSColor.black
    let letterAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.48, weight: .heavy),
        .foregroundColor: color,
    ]
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.34, weight: .bold),
        .foregroundColor: color,
    ]

    let left = NSAttributedString(string: "A", attributes: letterAttrs)
    let mid = NSAttributedString(string: "⇄", attributes: arrowAttrs)
    let right = NSAttributedString(string: "Я", attributes: letterAttrs)

    let total = left.size().width + mid.size().width * 0.9 + right.size().width
    var x = (s - total) / 2
    let baseY = s * 0.16
    left.draw(at: NSPoint(x: x, y: baseY))
    x += left.size().width - s * 0.02
    mid.draw(at: NSPoint(x: x, y: baseY + s * 0.10))
    x += mid.size().width * 0.9 - s * 0.03
    right.draw(at: NSPoint(x: x, y: baseY))

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, _ path: String) {
    let w = Int(image.size.width)
    let h = Int(image.size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

try! FileManager.default.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: statusIconDir, withIntermediateDirectories: true)

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    savePNG(drawAppIcon(CGFloat(pixels)), "\(appIconDir)/icon_\(pixels).png")
}
savePNG(drawStatusIcon(36), "\(statusIconDir)/status_1x.png")
savePNG(drawStatusIcon(72), "\(statusIconDir)/status_2x.png")

print("icons generated")
