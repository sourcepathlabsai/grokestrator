import Foundation
import Network
import GrokestratorCore

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
    /// `timeout` is nil when the caller didn't specify one (use the default).
    private var delegateHandler: (@Sendable (_ callerID: UUID?, _ child: String, _ task: String, _ timeout: TimeInterval?) async -> String)?

    /// Phase 3 workflow DB — schema-validated task exchange (`design/11`).
    private var database: OrchestrationDatabaseImpl?

    /// Progress reporting, child policy, and triggers (`#135`).
    private var taskReportHandler: (@Sendable (_ callerID: UUID?, _ status: String, _ result: String) async -> String)?
    private var nodeConfigureHandler: (@Sendable (_ callerID: UUID?, _ child: String, _ policyJSON: String) async -> String)?
    private var triggerScheduleHandler: (@Sendable (_ callerID: UUID?, _ child: String, _ when: String, _ task: String) async -> String)?
    private var triggerFireHandler: (@Sendable (_ callerID: UUID?, _ event: String, _ payload: String) async -> String)?
    private var oracleProposeHandler: (@Sendable (
        _ callerID: UUID?,
        _ target: String,
        _ markdown: String,
        _ rationale: String
    ) async -> String)?

    /// Header grok forwards on every MCP request, carrying the calling Node's id.
    public static let nodeHeader = "X-Grokestrator-Node"

    public init() {}

    /// Install the real delegation router (Phase 1c). Safe to call before/after start.
    public func setDelegateHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ child: String, _ task: String, _ timeout: TimeInterval?) async -> String) {
        self.delegateHandler = handler
    }

    public func setTaskReportHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ status: String, _ result: String) async -> String) {
        self.taskReportHandler = handler
    }

    public func setNodeConfigureHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ child: String, _ policyJSON: String) async -> String) {
        self.nodeConfigureHandler = handler
    }

    public func setTriggerScheduleHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ child: String, _ when: String, _ task: String) async -> String) {
        self.triggerScheduleHandler = handler
    }

    public func setTriggerFireHandler(_ handler: @escaping @Sendable (_ callerID: UUID?, _ event: String, _ payload: String) async -> String) {
        self.triggerFireHandler = handler
    }

    public func setOracleProposeHandler(_ handler: @escaping @Sendable (
        _ callerID: UUID?,
        _ target: String,
        _ markdown: String,
        _ rationale: String
    ) async -> String) {
        self.oracleProposeHandler = handler
    }

    /// Wire the embedded orchestration DB (Phase 3). Safe to call before/after start.
    public func setDatabase(_ database: OrchestrationDatabaseImpl) {
        self.database = database
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

    fileprivate func runDelegate(callerID: UUID?, child: String, task: String, timeout: TimeInterval? = nil) async -> String {
        if let handler = delegateHandler { return await handler(callerID, child, task, timeout) }
        return "Delegation is not wired yet (orchestration Phase 1c). "
             + "Received child=\"\(child)\", task=\"\(task)\"."
    }

    fileprivate func runTool(name: String?, argsData: Data, callerID: UUID?) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
        switch name {
        case "delegate":
            let child = args["child"] as? String ?? ""
            let task = args["task"] as? String ?? ""
            let timeout = (args["timeout"] as? Int).map { TimeInterval($0) }
            let handler = delegateHandler
            let text = await Self.runOffActor { await handler?(callerID, child, task, timeout) }
                ?? "Delegation is not wired yet."
            return (text, false)
        case "task.report":
            let status = args["status"] as? String ?? "unknown"
            let result = args["result"] as? String ?? ""
            let handler = taskReportHandler
            let text = await Self.runOffActor { await handler?(callerID, status, result) }
                ?? "task.report is not wired yet."
            return (text, false)
        case "node.configure":
            let child = args["child"] as? String ?? ""
            let policyObj = args["policy"] ?? [:]
            let policyJSON = (try? JSONSerialization.data(withJSONObject: policyObj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let handler = nodeConfigureHandler
            let text = await Self.runOffActor { await handler?(callerID, child, policyJSON) }
                ?? "node.configure is not wired yet."
            return (text, false)
        case "trigger.schedule":
            let child = args["child"] as? String ?? ""
            let when = args["when"] as? String ?? args["cron"] as? String ?? ""
            let task = args["task"] as? String ?? ""
            let handler = triggerScheduleHandler
            let text = await Self.runOffActor { await handler?(callerID, child, when, task) }
                ?? "trigger.schedule is not wired yet."
            return (text, false)
        case "trigger.fire":
            let event = args["event"] as? String ?? ""
            let payload: String = if let s = args["payload"] as? String { s }
                else if let obj = args["payload"] { String(describing: obj) } else { "" }
            let handler = triggerFireHandler
            let text = await Self.runOffActor { await handler?(callerID, event, payload) }
                ?? "trigger.fire is not wired yet."
            return (text, false)
        case "oracle.propose":
            let target = args["target"] as? String ?? ""
            let markdown = args["markdown"] as? String ?? ""
            let rationale = args["rationale"] as? String ?? ""
            let handler = oracleProposeHandler
            let text = await Self.runOffActor { await handler?(callerID, target, markdown, rationale) }
                ?? "oracle.propose is not wired yet."
            return (text, false)
        case "db.createSchema", "db.insert", "db.query", "db.update", "db.listTables":
            return await runDBTool(name: name!, args: args, callerID: callerID)
        default:
            return ("Unknown tool: \(name ?? "nil")", true)
        }
    }

    /// Run long-running orchestration handlers without pinning the MCP actor (#136).
    private static func runOffActor(_ work: @escaping @Sendable () async -> String?) async -> String? {
        await Task.detached(priority: .userInitiated) { await work() }.value
    }

    fileprivate func runDBTool(name: String, args: [String: Any], callerID: UUID?) async -> (String, Bool) {
        guard let database else {
            return ("Orchestration DB is not available.", true)
        }
        let contextID = callerID?.uuidString
        do {
            switch name {
            case "db.createSchema":
                let tableName = args["name"] as? String ?? ""
                guard let schemaObj = args["schema"],
                      let schemaData = try? JSONSerialization.data(withJSONObject: schemaObj),
                      let schema = try? JSONDecoder().decode(TableSchema.self, from: schemaData) else {
                    return ("db.createSchema requires `name` and `schema` (TableSchema JSON).", true)
                }
                try await database.createSchema(name: tableName, schema: schema)
                return ("Created schema for table \"\(tableName)\" (\(schema.columns.count) columns).", false)

            case "db.insert":
                let table = args["table"] as? String ?? ""
                guard let rowObj = args["row"] as? [String: Any] else {
                    return ("db.insert requires `table` and `row`.", true)
                }
                let row = Self.parseDBRow(rowObj)
                let rowID = try await database.insert(table: table, row: row, contextID: contextID)
                return ("Inserted row \(rowID) into \"\(table)\".", false)

            case "db.query":
                let table = args["table"] as? String ?? ""
                let predicate = (args["predicate"] as? [String: Any]).map(Self.parseDBRow)
                let limit = args["limit"] as? Int
                let rows = try await database.query(table: table, predicate: predicate, limit: limit)
                let json = try String(data: JSONEncoder().encode(rows), encoding: .utf8) ?? "[]"
                return (json, false)

            case "db.update":
                let table = args["table"] as? String ?? ""
                guard let valuesObj = args["values"] as? [String: Any] else {
                    return ("db.update requires `table` and `values`.", true)
                }
                let values = Self.parseDBRow(valuesObj)
                let predicate = (args["predicate"] as? [String: Any]).map(Self.parseDBRow)
                let changed = try await database.update(table: table, values: values, predicate: predicate)
                return ("Updated \(changed) row(s) in \"\(table)\".", false)

            case "db.listTables":
                let tables = try await database.listTables()
                let json = try String(data: JSONEncoder().encode(tables), encoding: .utf8) ?? "[]"
                return (json, false)

            default:
                return ("Unknown db tool: \(name)", true)
            }
        } catch let err as OrchestrationDBError {
            return (err.localizedDescription ?? String(describing: err), true)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private static func parseDBRow(_ dict: [String: Any]) -> DBRow {
        var row: DBRow = [:]
        for (key, value) in dict { row[key] = parseDBValue(value) }
        return row
    }

    private static func parseDBValue(_ value: Any) -> DBValue {
        if value is NSNull { return .null }
        if let s = value as? String { return .text(s) }
        if let i = value as? Int { return .integer(Int64(i)) }
        if let i = value as? Int64 { return .integer(i) }
        if let d = value as? Double { return .real(d) }
        if let b = value as? Bool { return .boolean(b) }
        if let nested = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: nested),
           let decoded = try? JSONDecoder().decode(DBValue.self, from: data) {
            return decoded
        }
        return .text(String(describing: value))
    }

    private static var oracleProposeTool: [String: Any] {
        [
            "name": "oracle.propose",
            "description": """
                Propose an update to the project's design oracle or design docs. \
                The proposal is queued for human review in Grokestrator Settings → Oracle; \
                nothing is merged until approved.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": [
                        "type": "string",
                        "description": "Repo-relative path under design/, e.g. design/oracle/invariants/INV-example.md",
                    ],
                    "markdown": ["type": "string", "description": "Full proposed markdown file body."],
                    "rationale": ["type": "string", "description": "One-line why this change belongs in the corpus."],
                ],
                "required": ["target", "markdown"],
            ],
        ]
    }

    private static var allToolSchemas: [[String: Any]] {
        [
            delegateToolSchema, taskReportTool, nodeConfigureTool,
            triggerScheduleTool, triggerFireTool, oracleProposeTool,
            dbCreateSchemaTool, dbInsertTool, dbQueryTool, dbUpdateTool, dbListTablesTool,
        ]
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
            result = ["tools": Self.allToolSchemas]
        case "tools/call":
            let callParams = params
            let name = callParams["name"] as? String
            let args = callParams["arguments"] as? [String: Any] ?? [:]
            let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
            let (text, isError) = await server.runTool(name: name, argsData: argsData, callerID: req.nodeID)
            result = ["content": [["type": "text", "text": text]], "isError": isError]
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

    private static var dbCreateSchemaTool: [String: Any] {
        [
            "name": "db.createSchema",
            "description": "Register a task table schema. The schema is the first data oracle — malformed writes are rejected.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Table name."],
                    "schema": ["type": "object", "description": "TableSchema JSON: { name, columns: [{ name, type, isRequired?, isUnique? }], description? }."],
                ],
                "required": ["name", "schema"],
            ],
        ]
    }

    private static var dbInsertTool: [String: Any] {
        [
            "name": "db.insert",
            "description": "Insert a validated row into a registered table.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": ["type": "string"],
                    "row": ["type": "object", "description": "Column name → value map."],
                ],
                "required": ["table", "row"],
            ],
        ]
    }

    private static var dbQueryTool: [String: Any] {
        [
            "name": "db.query",
            "description": "Query rows from a registered table (equality predicate, optional limit).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": ["type": "string"],
                    "predicate": ["type": "object", "description": "Optional column = value filters."],
                    "limit": ["type": "integer"],
                ],
                "required": ["table"],
            ],
        ]
    }

    private static var dbUpdateTool: [String: Any] {
        [
            "name": "db.update",
            "description": "Update rows matching an optional predicate. Values are schema-validated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": ["type": "string"],
                    "values": ["type": "object"],
                    "predicate": ["type": "object"],
                ],
                "required": ["table", "values"],
            ],
        ]
    }

    private static var dbListTablesTool: [String: Any] {
        [
            "name": "db.listTables",
            "description": "List registered orchestration tables.",
            "inputSchema": ["type": "object", "properties": [:]],
        ]
    }

    private static var taskReportTool: [String: Any] {
        [
            "name": "task.report",
            "description": "Report progress or a final result up to the orchestrator run store.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "description": "running | completed | failed | blocked"],
                    "result": ["type": "string", "description": "Human-readable progress or result text."],
                ],
                "required": ["status", "result"],
            ],
        ]
    }

    private static var nodeConfigureTool: [String: Any] {
        [
            "name": "node.configure",
            "description": "Grant or scope a child agent's ToolPolicy (capability mode + optional tool-name allowlist).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "child": ["type": "string"],
                    "policy": ["type": "object", "description": "ToolPolicy JSON: { capability: readOnly|readWrite|execute, allowed?: [tool names] }."],
                ],
                "required": ["child", "policy"],
            ],
        ]
    }

    private static var triggerScheduleTool: [String: Any] {
        [
            "name": "trigger.schedule",
            "description": "Schedule a standing child agent: interval (`every 30m`, `every 1h`) or event subscription (`event:pr-merged`).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "child": ["type": "string"],
                    "when": ["type": "string", "description": "Interval: every Nm/Nh/Nd. Event: event:<name> (fired via trigger.fire)."],
                    "task": ["type": "string", "description": "Prompt template fired on each wake."],
                ],
                "required": ["child", "when", "task"],
            ],
        ]
    }

    private static var triggerFireTool: [String: Any] {
        [
            "name": "trigger.fire",
            "description": "Emit an event that may wake subscribed standing agents.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "event": ["type": "string"],
                    "payload": ["type": "string"],
                ],
                "required": ["event"],
            ],
        ]
    }

    private static var delegateToolSchema: [String: Any] {
        [
            "name": "delegate",
            "description": """
                Delegate a task to one of your named descendant Connections and return its result. \
                Each descendant is a separate, observable Connection — a leaf worker or a \
                sub-orchestrator that may further delegate.

                WHEN TO USE: You are a fleet orchestrator (API/local brain). Do NOT perform \
                substantial work yourself (writing code, running commands, deep \
                analysis). Instead, decompose the work into cohesive units and \
                delegate each to the appropriate descendant by name. Synthesize \
                all results into a final deliverable.

                PARALLEL DELEGATION: Call this tool multiple times in one turn for \
                independent subtasks — concurrent calls run in parallel. Each call blocks \
                until that descendant finishes (or times out).

                TASK SIZING: Each delegation should be a self-contained task large \
                enough to warrant its own reasoning — not a single-line edit. The \
                child will see only the `task` text you provide; include all \
                necessary context.

                TIMEOUT: Default 120 seconds. If a child times out, it keeps \
                running — you'll get a timeout notice but no result. Set a longer \
                timeout for complex tasks.

                Children should return a JSON finding envelope (`envelope_version`, `status`, \
                `summary`, `findings[]`, `gaps[]`). Prose-only returns are wrapped with a warning.

                The human can watch each child's live transcript in a separate pane.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "child": [
                        "type": "string",
                        "description": "Name of the descendant to delegate to (direct child or deeper in your subtree).",
                    ],
                    "task": [
                        "type": "string",
                        "description": "The full task/prompt to send the child. Include all context it needs — it has no memory of your prior conversation.",
                    ],
                    "timeout": [
                        "type": "integer",
                        "description": "Max seconds to wait for the child's result (default 120). Use higher values for complex tasks.",
                    ],
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
