import Foundation
import Network

/// The spine of the orchestration platform: a tiny in-app MCP server that grok
/// Nodes connect to so an orchestrator can drive its children through tools we
/// implement (and can therefore log, validate, and oracle-check). See
/// `design/11-orchestration-platform.md` §2.2.
///
/// Transport: **MCP Streamable HTTP** — the shape grok 0.2.22 speaks (verified
/// against `grok mcp doctor` and the ACP `mcpCapabilities.http` handshake). grok
/// keeps the TCP connection alive and sends a sequence of JSON-RPC POSTs:
/// `initialize` → `notifications/initialized` → `tools/list` → `tools/call`. It
/// also probes `/.well-known/oauth-*` first (we 404 those) and opens a GET SSE
/// channel (we 405 it — synchronous tool calls don't need server push).
///
/// Bound to **loopback only**: orchestration is host-local (the Mac that owns the
/// Connections drives them; remote devices observe + answer). The grok child
/// processes run on this same Mac, so 127.0.0.1 is both sufficient and the trust
/// boundary.
///
/// Phase 1b exposes exactly one tool, `delegate`, stubbed here; Phase 1c installs
/// the real router via `setDelegateHandler`.
public actor OrchestrationMCPServer {
    private var listener: NWListener?
    public private(set) var port: UInt16?

    /// The router that performs a delegation. `callerID` is the calling Node's id
    /// (from the per-session header), so the router can scope to *its* children.
    private var delegateHandler: (@Sendable (_ callerID: UUID?, _ child: String, _ task: String) async -> String)?

    /// Header grok forwards on every MCP request, carrying the calling Node's id.
    public static let nodeHeader = "X-Grokestrator-Node"

    public init() {}

    /// Install the real delegation router (Phase 1c). Safe to call before/after start.
    public func setDelegateHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ child: String, _ task: String) async -> String) {
        self.delegateHandler = handler
    }

    /// Start on `port`, bound to 127.0.0.1. Idempotent.
    public func start(port: UInt16) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — host-local by construction (the grok children run on
        // this same Mac); never exposed on the LAN/Tailscale interface.
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        l.newConnectionHandler = { conn in
            Task.detached { await OrchestrationMCPServer.serve(conn, server: self) }
        }
        l.stateUpdateHandler = { _ in }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        self.port = port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// The URL a grok session/new entry should point at for this server.
    public static func url(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    /// Fixed loopback port for the in-app orchestration MCP server.
    public static let defaultPort: UInt16 = 7849

    /// Whether the in-app server is listening, so a launching grok session only
    /// advertises it when it's actually reachable. Set once at app launch (after a
    /// successful `start`) and read when building `session/new`. Single one-time
    /// write before any session is created in practice.
    public nonisolated(unsafe) static var isActive = false

    fileprivate func runDelegate(callerID: UUID?, child: String, task: String) async -> String {
        if let handler = delegateHandler { return await handler(callerID, child, task) }
        return "Delegation is not wired yet (orchestration Phase 1c). "
             + "Received child=\"\(child)\", task=\"\(task)\"."
    }

    // MARK: - Connection loop (keep-alive: many requests per connection)

    private static func serve(_ conn: NWConnection, server: OrchestrationMCPServer) async {
        conn.start(queue: .global(qos: .userInitiated))
        defer { conn.cancel() }
        var buffer = Data()
        while true {
            guard let req = await readRequest(conn, buffer: &buffer) else { return }
            guard let response = await handle(req, server: server) else { return }
            guard await send(conn, response) else { return }
        }
    }

    private struct Request { let method: String; let path: String; let body: Data; let nodeID: UUID? }

    /// Build the HTTP response for one parsed request. Returns nil to drop the
    /// connection. Notifications get a bodyless 202; everything else a JSON body.
    private static func handle(_ req: Request, server: OrchestrationMCPServer) async -> Data? {
        // OAuth discovery probes grok fires before the MCP handshake — decline fast.
        if req.path.contains("/.well-known/") { return httpResponse(404, "Not Found") }
        // grok opens a GET for the server→client SSE channel; we don't push.
        if req.method == "GET" { return httpResponse(405, "Method Not Allowed") }
        if req.method != "POST" { return httpResponse(405, "Method Not Allowed") }

        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return httpResponse(400, "Bad Request")
        }
        let method = msg["method"] as? String
        let id = msg["id"]   // absent ⇒ notification
        let params = msg["params"] as? [String: Any] ?? [:]

        // Notification (no id): acknowledge with 202, no JSON-RPC body.
        guard let id else { return httpResponse(202, "Accepted") }

        let result: [String: Any]
        switch method {
        case "initialize":
            let proto = (params["protocolVersion"] as? String) ?? "2025-06-18"
            result = [
                "protocolVersion": proto,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "grokestrator", "version": "0.1"],
            ]
        case "tools/list":
            result = ["tools": [delegateToolSchema]]
        case "tools/call":
            let callParams = params
            let name = callParams["name"] as? String
            let args = callParams["arguments"] as? [String: Any] ?? [:]
            if name == "delegate" {
                let child = args["child"] as? String ?? ""
                let task = args["task"] as? String ?? ""
                let text = await server.runDelegate(callerID: req.nodeID, child: child, task: task)
                result = ["content": [["type": "text", "text": text]], "isError": false]
            } else {
                result = ["content": [["type": "text", "text": "Unknown tool: \(name ?? "nil")"]], "isError": true]
            }
        case "ping":
            result = [:]
        default:
            result = [:]
        }

        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let json = try? JSONSerialization.data(withJSONObject: envelope) else {
            return httpResponse(500, "Internal Server Error")
        }
        return jsonResponse(json)
    }

    private static var delegateToolSchema: [String: Any] {
        [
            "name": "delegate",
            "description": "Delegate a task to one of your child Connections (agents) and "
                + "return its result. `child` is the child Connection's name; `task` is the "
                + "instruction to send it. The child runs as its own observable grok session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "child": ["type": "string", "description": "Name of the child Connection to delegate to."],
                    "task": ["type": "string", "description": "The task/prompt to send the child."],
                ],
                "required": ["child", "task"],
            ],
        ]
    }

    // MARK: - HTTP plumbing

    /// Read one HTTP request off the connection, honoring `Content-Length`. The
    /// `buffer` carries leftover bytes between requests (keep-alive).
    private static func readRequest(_ conn: NWConnection, buffer: inout Data) async -> Request? {
        let terminator = Data("\r\n\r\n".utf8)
        // Accumulate until we have the full header block.
        while buffer.firstRange(of: terminator) == nil {
            guard let chunk = await receive(conn), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.count > 1_048_576 { return nil }   // runaway header guard
        }
        guard let term = buffer.firstRange(of: terminator) else { return nil }
        let headerLen = buffer.distance(from: buffer.startIndex, to: term.lowerBound)
        let bodyStart = buffer.distance(from: buffer.startIndex, to: term.upperBound)
        let headerStr = String(decoding: buffer.prefix(headerLen), as: UTF8.self)
        let lines = headerStr.components(separatedBy: "\r\n")
        let tokens = (lines.first ?? "").split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let path = String(tokens[1])
        let contentLength = lines.lazy
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        // The calling Node's id, forwarded by grok on every request, so the router
        // can scope `delegate` to this orchestrator's children.
        let nodeID = lines.lazy
            .first { $0.lowercased().hasPrefix(Self.nodeHeader.lowercased() + ":") }
            .flatMap { UUID(uuidString: $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }

        let total = bodyStart + contentLength
        while buffer.count < total {
            guard let chunk = await receive(conn), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        let body = Data(buffer.dropFirst(bodyStart).prefix(contentLength))
        buffer = Data(buffer.dropFirst(total))    // keep leftover for the next request
        return Request(method: method, path: path, body: body, nodeID: nodeID)
    }

    private static func jsonResponse(_ json: Data) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Mcp-Session-Id: grokestrator\r\n"
        head += "Content-Length: \(json.count)\r\n"
        head += "\r\n"
        return Data(head.utf8) + json
    }

    private static func httpResponse(_ code: Int, _ reason: String) -> Data {
        Data("HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\n\r\n".utf8)
    }

    private static func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { d, _, _, error in
                cont.resume(returning: error == nil ? (d ?? Data()) : nil)
            }
        }
    }

    @discardableResult
    private static func send(_ conn: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.send(content: data, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
        }
    }
}
