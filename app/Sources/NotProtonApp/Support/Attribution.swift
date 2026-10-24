
import AppKit

enum Attribution {

    static let website = "https://cartouche.bryann2k.dev"
    static let github = "https://github.com/BRYANN2K/cartouche"

    // English, word for word as README and NOTICE carry it
    static let nonAffiliation = "Cartouche is now its own project, not built on NotProton. "
        + "It is not affiliated with NotProton, Valve, Apple or CodeWeavers."

    static var credits: String { credits(in: nil) }

    static func credits(in bundle: Bundle?) -> String {
        [
            String(localized: "Your games. Your Mac.", bundle: bundle),
            String(localized: "PC games, console classics and your favorite stores, together in one library. Install, play and tune your setup in an app made for macOS.", bundle: bundle),
            String(localized: "Free and open source.", bundle: bundle),
            "\(String(localized: "Website", bundle: bundle)) · GitHub",
        ].joined(separator: "\n\n")
    }

    @MainActor
    static func showAboutPanel() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        let linked = NSMutableAttributedString(attributedString: text)
        let fullText = linked.string as NSString
        let headline = linked.string.components(separatedBy: "\n").first ?? ""
        linked.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .semibold),
                            range: NSRange(location: 0, length: headline.utf16.count))
        linked.addAttribute(.link, value: website, range: fullText.range(of: String(localized: "Website"), options: .backwards))
        linked.addAttribute(.link, value: github, range: fullText.range(of: "GitHub", options: .backwards))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: linked])
        NSApp.activate()
    }
}
