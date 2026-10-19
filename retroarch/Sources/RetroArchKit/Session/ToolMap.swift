import Foundation

// The RetroArch tools Cartouche calls, matched by name against what the
// running build lists, with the parameters Cartouche sends. A build whose
// list lacks one leaves that need unavailable rather than failing the session.
public struct ToolMap: Sendable, Equatable {

    public enum Need: String, CaseIterable, Sendable {
        case loadContent
        case status
        case state
        case screenshot
        case closeContent
        case quit
        case readMemory

        public var tool: String {
            switch self {
            case .loadContent: "LOAD_CONTENT"
            case .status: "GET_STATUS"
            case .state: "STATE"
            case .screenshot: "SCREENSHOT"
            case .closeContent: "CLOSE_CONTENT"
            case .quit: "QUIT"
            case .readMemory: "READ_CORE_MEMORY"
            }
        }

        // Parameter name, and the values Cartouche sends when it is an enum
        var parameters: [(String, [String])] {
            switch self {
            case .loadContent: [("core", []), ("content", [])]
            case .state: [("action", ["save", "load"]), ("slot", [])]
            case .readMemory: [("address", []), ("bytes", [])]
            case .status, .screenshot, .closeContent, .quit: []
            }
        }
    }

    public private(set) var tools: [String: MCPTool]
    public private(set) var available: Set<Need>

    public init(_ listed: [MCPTool]) {
        let tools = Dictionary(listed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.tools = tools
        available = Set(Need.allCases.filter { need in
            guard let tool = tools[need.tool] else { return false }
            return need.parameters.allSatisfy { name, values in
                guard let parameter = tool.parameters[name] else { return false }
                let offered = Set(parameter["enum"]?.array?.compactMap(\.string) ?? [])
                return values.isEmpty || offered.isSuperset(of: values)
            }
        })
    }

    public var missing: [Need] { Need.allCases.filter { !available.contains($0) } }

    public func tool(for need: Need) throws -> String {
        guard available.contains(need) else { throw RetroArchSessionError.toolUnavailable(need.tool) }
        return need.tool
    }
}

// What GET_STATUS answers: "GET_STATUS PLAYING super_nes,game.sfc",
// "GET_STATUS PAUSED ...", or "GET_STATUS CONTENTLESS"
public struct GameStatus: Sendable, Equatable {
    public enum State: String, Sendable { case playing, paused, contentless }

    public var state: State
    public var system: String?
    public var content: String?

    public init(state: State, system: String? = nil, content: String? = nil) {
        self.state = state
        self.system = system
        self.content = content
    }

    public init?(reply: String) {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("GET_STATUS ") else { return nil }
        let rest = line.dropFirst("GET_STATUS ".count)
        if rest == "CONTENTLESS" {
            self.init(state: .contentless)
            return
        }
        let word = rest.prefix { $0 != " " }
        guard let state = State(rawValue: word.lowercased()), state != .contentless else { return nil }
        // A system id has no comma; the file name after it may have several
        let detail = rest.dropFirst(word.count).drop { $0 == " " }
        let system = detail.prefix { $0 != "," }
        let content = detail.dropFirst(system.count).dropFirst()
        self.init(
            state: state,
            system: system.isEmpty ? nil : String(system),
            content: content.isEmpty ? nil : String(content)
        )
    }
}
