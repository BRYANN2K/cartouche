// Draws the disk image window's background: where to drag Cartouche, and the
// three steps of the first open. make-dmg.sh uses the PNGs committed next to
// this file; run it again after changing the text.
//
//   swift packaging/dmg/background.swift packaging/dmg

import AppKit

let size = CGSize(width: 660, height: 400)
// Icon centers, shared with make-dmg.sh
let appIcon = CGPoint(x: 170, y: 120)
let applicationsIcon = CGPoint(x: 490, y: 120)

let heading = "Drag Cartouche to Applications. The first time you open it:"
let steps = [
    "macOS says it can’t check Cartouche. Click Done.",
    "Open System Settings > Privacy & Security, scroll down, click Open Anyway.",
    "Confirm with your password. Updates won’t ask again.",
]
let note = """
    Cartouche is free and signed with its own certificate, not notarized by Apple. \
    The certificate does not remove this warning, but it keeps updates and the permissions \
    you grant from resetting. The install script in the README avoids the warning.
    """

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    // Flipped, so y grows downward as in Finder's icon positions
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()

    let gray = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
    let arrow = NSBezierPath()
    let y = appIcon.y
    arrow.move(to: CGPoint(x: appIcon.x + 90, y: y))
    arrow.line(to: CGPoint(x: applicationsIcon.x - 90, y: y))
    arrow.move(to: CGPoint(x: applicationsIcon.x - 102, y: y - 10))
    arrow.line(to: CGPoint(x: applicationsIcon.x - 90, y: y))
    arrow.line(to: CGPoint(x: applicationsIcon.x - 102, y: y + 10))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    gray.setStroke()
    arrow.stroke()

    let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    let left: CGFloat = 60, width = size.width - 2 * left
    func draw(_ text: String, at top: CGFloat, font: NSFont, color: NSColor, x: CGFloat = left) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let box = string.boundingRect(with: CGSize(width: width - (x - left), height: 200), options: [.usesLineFragmentOrigin])
        string.draw(with: CGRect(x: x, y: top, width: width - (x - left), height: ceil(box.height)), options: [.usesLineFragmentOrigin])
        return top + ceil(box.height)
    }
    var top = draw(heading, at: 228, font: .systemFont(ofSize: 14, weight: .semibold), color: ink) + 8
    for (i, step) in steps.enumerated() {
        _ = draw("\(i + 1).", at: top, font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: ink)
        top = draw(step, at: top, font: .systemFont(ofSize: 13), color: ink, x: left + 20) + 5
    }
    _ = draw(note, at: max(top + 10, 330), font: .systemFont(ofSize: 11), color: gray)

    NSGraphicsContext.restoreGraphicsState()
    // 144 dpi for the 2x image, which tiffutil -cathidpicheck asks for
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try render(scale: 1).write(to: folder.appending(path: "background.png"))
try render(scale: 2).write(to: folder.appending(path: "background@2x.png"))
print("==> background.swift: wrote background.png and background@2x.png in \(folder.path(percentEncoded: false))")
