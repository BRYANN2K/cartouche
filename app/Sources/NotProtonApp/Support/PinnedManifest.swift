// A bundled JSON of pinned downloads, validated before anything installs from it.

import Foundation

protocol PinnedManifest: Codable, Equatable, Sendable {
    static var format: Int { get }
    static var resource: String { get }
    var format: Int { get }
    func problems() -> [String]
}

struct ManifestInvalid: Error, Equatable, CustomStringConvertible {
    let problems: [String]
    var description: String { problems.joined(separator: "; ") }
}

extension PinnedManifest {

    static func read(_ data: Data) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        let problems = manifest.problems()
        guard problems.isEmpty else { throw ManifestInvalid(problems: problems) }
        return manifest
    }

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw ManifestInvalid(problems: ["\(resource).json is not in the app"])
        }
        return try read(Data(contentsOf: url))
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
