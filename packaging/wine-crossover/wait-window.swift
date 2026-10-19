// Waits until a process whose name contains a word shows a normal on-screen
// window, and prints the seconds it took. Exits 1 after the timeout.
//
//   swift wait-window.swift <owner word> <timeout seconds>
//   swift wait-window.swift --list
//
// Matches the owner name, which needs no Screen Recording permission, unlike
// window titles.

import CoreGraphics
import Foundation

func windows() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}

func isNormal(_ window: [String: Any]) -> Bool {
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return layer == 0 && width >= 100 && height >= 100
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--list" {
    for window in windows() where isNormal(window) {
        print(window[kCGWindowOwnerName as String] as? String ?? "?")
    }
    exit(0)
}
guard args.count == 2, let timeout = Double(args.last!) else {
    FileHandle.standardError.write(Data("usage: wait-window.swift <owner word> <timeout seconds>\n".utf8))
    exit(2)
}
let word = args.first!.lowercased()
let start = Date()
while Date().timeIntervalSince(start) < timeout {
    let found = windows().contains { window in
        let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        return owner.contains(word) && isNormal(window)
    }
    if found {
        print(String(format: "%.1f", Date().timeIntervalSince(start)))
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.25)
}
FileHandle.standardError.write(Data("wait-window: no \(word) window after \(Int(timeout)) s\n".utf8))
exit(1)
