import AppKit

// Генератор иконок AbubTranslate: F⇄ф deep navy #0F1B2E premium minimal
// Запуск: swift Tools/GenerateIcons.swift

let root = "Sources/Assets.xcassets"
let appIconDir = "\(root)/AppIcon.appiconset"
let statusIconDir = "\(root)/StatusIcon.imageset"

// deep navy #0F1B2E
let deepNavy = NSColor(srgbRed: 0x0F/255.0, green: 0x1B/255.0, blue: 0x2E/255.0, alpha: 1)

func drawAppIcon(_ s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let body = NSBezierPath(
        roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02),
        xRadius: s * 0.23,
        yRadius: s * 0.23
    )
    // Flat deep navy, NO gradient, NO shadow — premium minimal
    deepNavy.setFill()
    body.fill()

    // Символ F⇄ф белый, flat, no shadow, high contrast
    // Три глифа: F, ⇄, ф — centered, optical balance
    let fSize = s * 0.34
    let arrowSize = s * 0.30
    let efSize = s * 0.34

    let fAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fSize, weight: .bold),
        .foregroundColor: NSColor.white,
        .kern: s * -0.01
    ]
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: arrowSize, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
    let efAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: efSize, weight: .bold),
        .foregroundColor: NSColor.white,
    ]

    let fStr = NSAttributedString(string: "F", attributes: fAttrs)
    let arrowStr = NSAttributedString(string: "⇄", attributes: arrowAttrs)
    let efStr = NSAttributedString(string: "ф", attributes: efAttrs)

    // Центрировать группу: общая ширина
    let totalW = fStr.size().width + arrowStr.size().width + efStr.size().width + s * 0.06
    var x = (s - totalW) / 2
    let yF = (s - fStr.size().height) / 2 + s * 0.02
    let yArrow = (s - arrowStr.size().height) / 2 + s * 0.01
    let yEf = (s - efStr.size().height) / 2 + s * 0.02

    fStr.draw(at: NSPoint(x: x, y: yF))
    x += fStr.size().width + s * 0.03
    arrowStr.draw(at: NSPoint(x: x, y: yArrow))
    x += arrowStr.size().width + s * 0.03
    efStr.draw(at: NSPoint(x: x, y: yEf))

    image.unlockFocus()
    return image
}

func drawStatusIcon(_ s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Template: monochrome black on transparent, isTemplate=true
    // Slightly rounded, 1.5px optical, premium minimal
    let color = NSColor.black
    let fAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.42, weight: .semibold),
        .foregroundColor: color,
    ]
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.32, weight: .regular),
        .foregroundColor: color,
    ]
    let efAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.42, weight: .semibold),
        .foregroundColor: color,
    ]

    let fStr = NSAttributedString(string: "F", attributes: fAttrs)
    let arrowStr = NSAttributedString(string: "⇄", attributes: arrowAttrs)
    let efStr = NSAttributedString(string: "ф", attributes: efAttrs)

    let total = fStr.size().width + arrowStr.size().width + efStr.size().width
    var x = (s - total) / 2
    // оптический центр чуть выше
    let y = (s - fStr.size().height) / 2 + s * 0.04
    let yArrow = y + s * 0.02

    fStr.draw(at: NSPoint(x: x, y: y))
    x += fStr.size().width - s * 0.02
    arrowStr.draw(at: NSPoint(x: x, y: yArrow))
    x += arrowStr.size().width - s * 0.02
    efStr.draw(at: NSPoint(x: x, y: y))

    image.unlockFocus()
    image.isTemplate = true
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

print("icons generated F⇄ф deep navy #0F1B2E")
