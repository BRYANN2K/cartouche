
import Foundation

struct PermissionLedger: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ permission: Permission, _ field: String) -> String {
        "permissions.\(permission.rawValue).\(field)"
    }

    func wasAsked(_ permission: Permission) -> Bool {
        defaults.bool(forKey: key(permission, "asked"))
    }

    func noteAsked(_ permission: Permission) {
        defaults.set(true, forKey: key(permission, "asked"))
    }

    func last(_ permission: Permission) -> PermissionState? {
        defaults.string(forKey: key(permission, "last")).flatMap(PermissionState.init(rawValue:))
    }

    // A result counts as asking: macOS has decided, so checking again does not prompt
    func note(_ state: PermissionState, for permission: Permission) {
        noteAsked(permission)
        defaults.set(state.rawValue, forKey: key(permission, "last"))
    }

    // Set by Open System Settings. Only then does Cartouche check again with a real read or write, because that check cannot prompt any more.
    func wantsRecheck(_ permission: Permission) -> Bool {
        defaults.bool(forKey: key(permission, "recheck"))
    }

    func setRecheck(_ wanted: Bool, for permission: Permission) {
        defaults.set(wanted, forKey: key(permission, "recheck"))
    }

    func target(_ permission: Permission) -> URL? {
        defaults.string(forKey: key(permission, "target")).map { URL(filePath: $0) }
    }

    func setTarget(_ url: URL?, for permission: Permission) {
        defaults.set(url?.path(percentEncoded: false), forKey: key(permission, "target"))
    }

    func offered(_ permission: Permission) -> Bool {
        defaults.bool(forKey: key(permission, "offered"))
    }

    func noteOffered(_ permission: Permission) {
        defaults.set(true, forKey: key(permission, "offered"))
    }
}
