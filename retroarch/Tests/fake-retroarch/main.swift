// A stand-in for RetroArch in the tests that need no real build. It speaks
// the same one-line JSON-RPC as --mcp-stdio, from a tools/list captured at
// the pinned commit, and can be told to misbehave.
//
//   FAKE_RA_ARGS         file to append argv to, one JSON array per launch
//   FAKE_RA_TOOLS        tools/list result to serve (JSON)
//   FAKE_RA_NO_MCP       --help does not offer --mcp-stdio
//   FAKE_RA_IGNORE_EOF   keeps running after stdin closes
//   FAKE_RA_IGNORE_TERM  ignores SIGTERM
//   FAKE_RA_EXIT         exits at once with this status

import Foundation

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

if let path = env["FAKE_RA_ARGS"] {
    let line = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line + Data("\n".utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line + Data("\n".utf8))
    }
}

if let code = env["FAKE_RA_EXIT"].flatMap(Int32.init) { exit(code) }

if args.contains("--version") {
    print("RetroArch - Frontend for libretro\nVersion: 1.22.2 (Git ed3187e) Oct 19 2026")
    exit(0)
}
if args.contains("--help") {
    print("Usage: retroarch [OPTIONS]... [FILE]")
    print("  -L, --libretro=FILE        Path to libretro implementation.")
    if env["FAKE_RA_NO_MCP"] == nil {
        print("      --mcp-stdio                Serves MCP on stdin and stdout, for a client that starts RetroArch.")
    }
    exit(0)
}

if env["FAKE_RA_IGNORE_TERM"] != nil { signal(SIGTERM, SIG_IGN) }

func hang() -> Never {
    while true { sleep(60) }
}

guard args.contains("--mcp-stdio") else { hang() }

var content: String?
let tools: Any = env["FAKE_RA_TOOLS"]
    .flatMap { FileManager.default.contents(atPath: $0) }
    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? ["tools": []]

// 1x1 PNG
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

func reply(_ id: Any, _ result: Any) {
    let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
    let data = try! JSONSerialization.data(withJSONObject: message)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func text(_ s: String, error: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": error]
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String
    else { continue }
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "RetroArch", "version": "1.22.2"],
        ])
    case "tools/list":
        reply(id, tools)
    case "tools/call":
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String {
        case "GET_STATUS":
            if let content {
                reply(id, text("GET_STATUS PLAYING fake,\(((content as NSString).lastPathComponent as NSString).deletingPathExtension)"))
            } else {
                reply(id, text("GET_STATUS CONTENTLESS"))
            }
        case "LOAD_CONTENT":
            let path = arguments["content"] as? String ?? ""
            if FileManager.default.fileExists(atPath: path) {
                content = path
                reply(id, text("LOAD_CONTENT \(path)"))
            } else {
                reply(id, text("LOAD_CONTENT ERROR no content at \(path)", error: true))
            }
        case "STATE":
            reply(id, text("STATE \(arguments["action"] ?? "") \(arguments["slot"] ?? "")"))
        case "SCREENSHOT":
            reply(id, ["content": [["type": "image", "data": png, "mimeType": "image/png"],
                                   ["type": "text", "text": "/tmp/fake.png"]], "isError": false])
        case "CLOSE_CONTENT":
            content = nil
            reply(id, text("Done."))
        case "QUIT":
            reply(id, text("QUIT pressed"))
            exit(0)
        default:
            reply(id, text("\(params["name"] ?? "") ERROR not in the fake", error: true))
        }
    default:
        let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method."]]
        FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: error) + Data("\n".utf8))
    }
}

if env["FAKE_RA_IGNORE_EOF"] != nil { hang() }
exit(0)
