// Simple logic

import Foundation

func atomicReplace(_ destination: URL, from source: URL, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: source, to: staging)

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let code = errno
        if code == EACCES || code == EPERM {
            throw WriteRefused(path: destination.path(percentEncoded: false))
        }
        let reason = String(cString: strerror(code))
        throw StepFailure(
            step: step,
            detail: String(localized: "Replacing \(destination.path(percentEncoded: false)) failed. \(reason)")
        )
    }
}

// The old folder moves aside before the new one lands, so a failed swap keeps
// the previous install usable; the leftover is removed once the new one is in
func swapIn(_ new: URL, at target: URL) throws {
    let fm = FileManager.default
    let aside = target.deletingLastPathComponent()
        .appending(path: ".\(target.lastPathComponent).\(UUID().uuidString)")
    var kept = false
    if fm.fileExists(atPath: target.path(percentEncoded: false)) {
        try fm.moveItem(at: target, to: aside)
        kept = true
    }
    do {
        try fm.moveItem(at: new, to: target)
    } catch {
        if kept { try? fm.moveItem(at: aside, to: target) }
        throw error
    }
    if kept { try? fm.removeItem(at: aside) }
}

func atomicReplace(_ destination: URL, with data: Data, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).new")
    try? fm.removeItem(at: staging)

    do {
        try data.write(to: staging)
    } catch {
        throw StepFailure(
            step: step,
            detail: String(localized: "\(staging.path(percentEncoded: false)) could not be written. ")
                + error.localizedDescription
        )
    }

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let reason = String(cString: strerror(errno))
        try? fm.removeItem(at: staging)
        throw StepFailure(
            step: step,
            detail: String(localized: "Replacing \(destination.path(percentEncoded: false)) failed. \(reason)")
        )
    }
}
