
import AppKit

enum Attribution {

    static let website = "https://cartouche.bryann2k.dev"

    static let credit = "Cartouche started as a fork of NotProton "
        + "(https://github.com/NotProtonNot/NotProton), by NotProtonNot and the NotProton contributors."

    static let license = "Cartouche is free software, licensed under the GNU General Public License "
        + "version 3 (GPL-3.0). Some parts carry their own licenses, listed in NOTICE."

    static let nonAffiliation = "Cartouche is now its own project, not built on NotProton. "
        + "It is not affiliated with NotProton, Valve, Apple or CodeWeavers."

    static var credits: String { [website, credit, license, nonAffiliation].joined(separator: "\n\n") }

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
        linked.addAttribute(.link, value: website, range: NSRange(location: 0, length: website.utf16.count))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: linked])
        NSApp.activate()
    }
}
