import Foundation
import Security

public enum MCPToken {

    // 32 bytes from the system CSPRNG, hex encoded
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in generator.next() }
        }
        return "cartouche-" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
