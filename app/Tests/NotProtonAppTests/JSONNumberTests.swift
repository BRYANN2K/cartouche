import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

// Whole numbers past Int64 come from untrusted JSON: shared-fix registries and agent arguments.
@Suite("Large JSON numbers")
struct JSONNumberTests {

    @Test("canonical JSON writes whole numbers between 2^63 and 1e21 as digits, as JavaScript does")
    func canonicalLargeWholeNumbers() {
        #expect(CanonicalJSON.number(9.3e18) == "9300000000000000000")
        #expect(CanonicalJSON.number(-9.3e18) == "-9300000000000000000")
        #expect(CanonicalJSON.number(0x1p63) == "9223372036854776000")
        #expect(CanonicalJSON.number(1e20) == "100000000000000000000")
        #expect(CanonicalJSON.number(1e21) == "1e+21")
        #expect(CanonicalJSON.number(42) == "42")
        #expect(CanonicalJSON.number(-0.0) == "0")
    }

    @Test("a registry carrying a huge whole number parses and canonicalizes without trapping")
    func canonicalParseHuge() throws {
        let value = try CanonicalJSON.parse(Data(#"{"n":12345678901234567890,"m":1}"#.utf8))
        #expect(CanonicalJSON.string(value).contains("12345678901234567000"))
    }

    @Test("JSONValue.int is nil past Int's range instead of trapping")
    func intOutOfRange() {
        #expect(JSONValue.number(1e19).int == nil)
        #expect(JSONValue.number(-1e19).int == nil)
        #expect(JSONValue.number(1e300).int == nil)
        #expect(JSONValue.number(.infinity).int == nil)
        #expect(JSONValue.number(2.5).int == nil)
        #expect(JSONValue.number(42).int == 42)
        #expect(JSONValue.number(-7).int == -7)
    }

    @Test("an agent's huge integer argument is invalid, not a crash")
    @MainActor
    func agentHugeInteger() async {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "cartouche-agent-tests")
            .appending(path: UUID().uuidString)
        let service = AgentService(backend: AgentFixture(home: root), level: .standard, home: root)
        let reply = await service.call("save_state", ["slot": .number(1e19)], client: "test")
        #expect(reply["isError"] == .bool(true))
    }
}
