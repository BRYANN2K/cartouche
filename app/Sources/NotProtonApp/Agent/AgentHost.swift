import AppKit
import CartoucheMCP
import Foundation
import RetroArchKit
import UserNotifications

@MainActor
@Observable
final class AgentControlModel {

    let service: AgentService

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }

    var httpEnabled = false {
        didSet {
            guard httpEnabled != oldValue else { return }
            defaults.set(httpEnabled, forKey: Self.httpKey)
            if enabled { stop(); start() }
        }
    }

    var httpPort: UInt16 {
        didSet {
            guard httpPort != oldValue else { return }
            defaults.set(Int(httpPort), forKey: Self.portKey)
            if enabled && httpEnabled { stop(); start() }
        }
    }

    // Bearer token for HTTP clients; kept in defaults so a restart does not break the client config.
    let token: String

    private(set) var socketState = "off"
    private(set) var httpState = "off"

    var level: AgentLevel {
        get { service.level }
        set {
            service.level = newValue
            defaults.set(newValue.rawValue, forKey: Self.levelKey)
        }
    }
    var pending: [AgentApproval] { service.pending }
    var actions: [AgentAction] { service.actions }
    var tools: [AgentTool] { service.tools.values.sorted { $0.name < $1.name } }

    private let defaults: UserDefaults
    private let socketURL: URL
    private var socket: MCPSocketServer?
    private var http: MCPHTTPServer?
    private let server: MCPServer

    private static let enabledKey = "agent.server.enabled"
    private static let httpKey = "agent.http.enabled"
    private static let portKey = "agent.http.port"
    private static let tokenKey = "agent.http.token"
    private static let levelKey = "agent.level"

    init(service: AgentService, defaults: UserDefaults = .standard,
         socket: URL = SupportPaths.agentSocket) {
        self.service = service
        self.defaults = defaults
        socketURL = socket
        server = MCPServer(handler: AgentHandling(service: service))
        httpPort = UInt16(exactly: defaults.integer(forKey: Self.portKey)) ?? 3398
        if let saved = defaults.string(forKey: Self.tokenKey), saved.count >= 16 {
            token = saved
        } else {
            token = "cartouche-" + UUID().uuidString.replacing("-", with: "").prefix(32)
            defaults.set(token, forKey: Self.tokenKey)
        }
        if let raw = defaults.string(forKey: Self.levelKey), let saved = AgentLevel(rawValue: raw) {
            service.level = saved
        }
        service.notify = { approval in AgentNotifier.post(approval) }
        AgentNotifier.onAnswer = { [service] id, allow in service.answer(id, allow: allow) }
        httpEnabled = defaults.bool(forKey: Self.httpKey)
        enabled = defaults.bool(forKey: Self.enabledKey)
        if enabled { start() }
        // The socket file must not outlive the app: stop() unlinks it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func pipe() -> @Sendable (Data) async -> Data {
        let server = server
        return { data in await server.handle(data: data) }
    }

    func start() {
        service.enabled = true
        if socket == nil {
            let helper = MCPSocketServer.bundledHelper()
            let server = MCPSocketServer(socket: socketURL, handler: pipe()) { path in
                path == helper
            }
            do {
                try server.start()
                socket = server
                socketState = "running"
            } catch {
                socketState = error.localizedDescription
            }
        }
        if httpEnabled, http == nil {
            let server = MCPHTTPServer(token: token, handler: pipe())
            // Ready and failure arrive asynchronously on the listener queue.
            server.onState = { [weak self] state in
                Task { @MainActor in self?.httpState = state }
            }
            do {
                try server.start(port: httpPort)
                http = server
            } catch {
                httpState = error.localizedDescription
            }
        }
    }

    func stop() {
        service.enabled = false
        service.denyPending()
        socket?.stop(); socket = nil
        http?.stop(); http = nil
        socketState = "off"
        httpState = "off"
    }

    var clientConfiguration: String {
        if httpEnabled {
            """
            {
              "mcpServers": {
                "cartouche": {
                  "url": "http://127.0.0.1:\(httpPort)/mcp",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """
        } else {
            """
            {
              "mcpServers": {
                "cartouche": { "command": "\(Self.jsonEscaped(MCPSocketServer.bundledHelper()))" }
              }
            }
            """
        }
    }

    static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func answer(_ approval: AgentApproval, allow: Bool) {
        service.answer(approval.id, allow: allow)
    }

    func undo(_ action: AgentAction) async {
        try? await service.undo(action.id)
    }
}

struct AgentHandling: @unchecked Sendable, MCPHandling {

    let service: AgentService
    var serverVersion: String { "cartouche-mcp/1" }
    // Last initialized client, mirrored off-actor so the protocol's sync accessor can read it.
    private let clientBox = ClientBox()

    var clientName: String { clientBox.name }

    func initialize(client: String) async {
        clientBox.name = client
        await MainActor.run { service.clientName = client }
    }

    func tools(client: String) async -> [MCPToolInfo] {
        await MainActor.run {
            service.tools.values.sorted { $0.name < $1.name }.map {
                MCPToolInfo(name: $0.name, detail: $0.detail, schema: $0.schema,
                            readOnly: $0.readOnly, destructive: $0.destructive)
            }
        }
    }

    func callTool(_ name: String, arguments: RetroArchKit.JSONValue,
                  client: String) async throws -> RetroArchKit.JSONValue {
        await service.call(name, arguments, client: client)
    }

    func resources(client: String) async -> [JSONValue] {
        AgentResources.all
    }

    func readResource(_ uri: String, client: String) async throws -> String {
        try await service.readResource(uri)
    }
}

// Off-actor name mirror; levels and approvals are the real boundary - any same-user process could run the bundled helper.
final class ClientBox: @unchecked Sendable {
    private var storage = "agent"
    private let lock = NSLock()
    var name: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

enum AgentResources {
    static let all: [JSONValue] = [
        ["uri": "cartouche://status", "name": "Agent server status", "mimeType": "application/json"],
        ["uri": "cartouche://pending", "name": "Pending approvals", "mimeType": "application/json"],
        ["uri": "cartouche://actions", "name": "Recent agent actions", "mimeType": "application/json"],
    ].map { dict in .object(dict.mapValues { .string($0) }) }
}
