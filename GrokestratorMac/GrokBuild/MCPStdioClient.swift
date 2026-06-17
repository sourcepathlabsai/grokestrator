import Foundation
import GrokestratorCore

/// A minimal **MCP client** over stdio for the app's model-agnostic (API-brain)
/// tool loop. Spawns a configured stdio MCP server, performs the JSON-RPC 2.0
/// handshake (`initialize` → `notifications/initialized` → `tools/list`), and
/// proxies `tools/call`. grok-backed Nodes don't need this (grok is its own MCP
/// client); this is what lets an `OpenAICompatSession` use the granted MCP servers.
/// stdio only for now (the registry's `http` transport is a fast follow).
actor MCPStdioClient {
    struct ToolSpec: Sendable {
        let name: String
        let description: String
        /// JSON-encoded input schema (kept as `Data` so the spec is `Sendable` across
        /// the actor boundary; decoded back to an object at the advertise site).
        let inputSchemaJSON: Data
    }

    let serverName: String
    private let server: MCPServerConfig
    private let cwd: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    /// Resolved with the JSON-RPC `result` re-encoded as `Data` (Sendable across the
    /// continuation); the caller decodes it back inside the actor.
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private(set) var tools: [ToolSpec] = []
    private var connected = false

    init(server: MCPServerConfig, cwd: String?) {
        self.server = server
        self.serverName = server.name
        self.cwd = cwd
    }

    /// Spawn + handshake + list tools. Idempotent; returns the tool specs. Throws on
    /// a non-stdio transport or a failed handshake.
    func connect() async throws -> [ToolSpec] {
        if connected { return tools }
        guard case .stdio(let command, let args, let env) = server.transport else {
            throw MCPError.unsupportedTransport
        }

        // Run through a login shell so the command resolves on PATH and the user's
        // profile env is in scope; `exec "$0" "$@"` passes argv through unquoted.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", command] + args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = LoginShellEnvironment.shared
        environment.merge(env) { _, new in new }
        p.environment = environment

        let stdoutPipe = Pipe(), stdinPipe = Pipe(), stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardInput = stdinPipe
        p.standardError = stderrPipe
        // Drain stderr so the server doesn't block on a full pipe.
        stderrPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }

        let (dataStream, dataCont) = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { dataCont.finish(); fh.readabilityHandler = nil } else { dataCont.yield(d) }
        }

        do { try p.run() } catch { throw MCPError.spawnFailed(error.localizedDescription) }
        self.process = p
        self.stdin = stdinPipe.fileHandleForWriting

        // Pump incoming JSON-RPC lines into the dispatcher.
        let reader = ACPMessageReader(dataStream: dataStream)
        Task { [weak self] in
            for await line in await reader.lines() {
                guard let self else { break }
                await self.dispatch(line)   // parse inside the actor (Data is Sendable)
            }
            await self?.handleClosed()
        }

        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "grokestrator", "version": "1.0"],
        ])
        notify("notifications/initialized", params: [:])

        let listResult = try await request("tools/list", params: [:])
        let rawTools = (listResult["tools"] as? [[String: Any]]) ?? []
        tools = rawTools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object"]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema))
                ?? Data(#"{"type":"object"}"#.utf8)
            return ToolSpec(name: name,
                            description: (t["description"] as? String) ?? "",
                            inputSchemaJSON: schemaData)
        }
        connected = true
        return tools
    }

    /// Call a tool by its (server-local) name; returns (text, isError).
    func call(_ name: String, argumentsJSON: String) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        do {
            let result = try await request("tools/call", params: ["name": name, "arguments": args], timeout: 120)
            let content = (result["content"] as? [[String: Any]]) ?? []
            let text = content.compactMap { block -> String? in
                if block["type"] as? String == "text" { return block["text"] as? String }
                return nil
            }.joined(separator: "\n")
            let isError = (result["isError"] as? Bool) ?? false
            return (text.isEmpty ? "(no content)" : text, isError)
        } catch {
            return ("MCP \(serverName) error: \(error.localizedDescription)", true)
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
        try? stdin?.close()
        stdin = nil
        for (_, c) in pending { c.resume(throwing: MCPError.closed) }
        pending.removeAll()
        connected = false
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            write(payload)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeout(id, method: method)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func notify(_ method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A) // '\n'
        try? stdin?.write(contentsOf: line)
    }

    private func dispatch(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let error = obj["error"] as? [String: Any] {
            cont.resume(throwing: MCPError.rpc((error["message"] as? String) ?? "rpc error"))
        } else {
            let result = (obj["result"] as? [String: Any]) ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
            cont.resume(returning: data)
        }
    }

    private func timeout(_ id: Int, method: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: MCPError.timeout(method))
        }
    }

    private func handleClosed() {
        for (_, c) in pending { c.resume(throwing: MCPError.closed) }
        pending.removeAll()
        connected = false
    }

    enum MCPError: LocalizedError {
        case unsupportedTransport, spawnFailed(String), rpc(String), timeout(String), closed
        var errorDescription: String? {
            switch self {
            case .unsupportedTransport: return "server transport not supported (stdio only)"
            case .spawnFailed(let m): return "spawn failed: \(m)"
            case .rpc(let m): return m
            case .timeout(let method): return "\(method) timed out"
            case .closed: return "server closed"
            }
        }
    }
}
