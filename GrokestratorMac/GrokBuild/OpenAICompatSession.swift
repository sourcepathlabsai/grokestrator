import Foundation
import GrokestratorCore

/// A model-agnostic brain (Phase B): runs the agent loop against an
/// **OpenAI-compatible** `/chat/completions` endpoint — Groq, Cerebras,
/// together.ai, LM Studio, Ollama, llama.cpp, Gemini's compat endpoint — and
/// **synthesizes `ACPEvent`s** (the universal event language) so everything above
/// the `AgentSession` seam (history, broadcast, transcript, delegate router,
/// role-prompt injection, overlays) works unchanged.
///
/// Online LLMs are stateless, so **we are the harness**: the conversation lives in
/// `messages` here and is re-sent on every call. That is also what makes brains
/// swappable mid-conversation. Tools are **executed by the app**, scoped to the
/// node's working directory (the mediation invariant — the model only acts through
/// tools we implement). Real per-action policy/guardrails are Phase C; this is a
/// minimal cwd-scoped executor.
public actor OpenAICompatSession: AgentSession {
    private let instanceID: UUID
    private let baseURL: String         // e.g. http://127.0.0.1:1234/v1
    private let model: String
    private let apiKey: String?
    private let cwd: String
    private let policy: ToolPolicy
    private var messages: [[String: Any]] = []
    /// When set, this Node can orchestrate: the `delegate` tool routes here (the
    /// manager installs a handler scoped to this Node's own children). nil ⇒ no
    /// `delegate` tool is offered.
    private var delegateHandler: (@Sendable (_ child: String, _ task: String) async -> String)?
    private var sessionId: String?
    private var usage = SessionUsage.empty
    private var cancelled = false
    private let maxIterations = 12
    private let outputCap = 8000        // lossless context discipline: cap tool output

    /// Granted MCP servers (set by the server from the Node's registry grant). Their
    /// tools are bridged into this loop so an API brain can use MCP too — gated by
    /// the grant (which servers) just like a grok Node. stdio only for now.
    private var mcpServers: [MCPServerConfig] = []
    private var mcpClients: [MCPStdioClient] = []
    private var mcpToolSchemas: [[String: Any]] = []                       // advertised to the model
    private var mcpRoute: [String: (client: MCPStdioClient, tool: String)] = [:]  // emitted name → call target
    private var mcpConnected = false

    /// Set the MCP servers this Node may use (filtered to stdio by the caller).
    public func setMCPServers(_ servers: [MCPServerConfig]) { mcpServers = servers }

    /// Shut down any spawned MCP server subprocesses. Called on stop so they don't
    /// outlive the session (the launcher can't kill them — they're spawned here).
    public func shutdownMCP() async {
        for client in mcpClients { await client.shutdown() }
        mcpClients.removeAll(); mcpToolSchemas.removeAll(); mcpRoute.removeAll()
        mcpConnected = false
    }

    public init(instanceID: UUID, baseURL: String, model: String, apiKey: String?, cwd: String?,
                policy: ToolPolicy = .unrestricted) {
        self.instanceID = instanceID
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        self.apiKey = apiKey
        self.cwd = cwd ?? FileManager.default.currentDirectoryPath
        self.policy = policy
    }

    /// Install the orchestration handler (manager-provided, scoped to this Node's
    /// children). Enables the `delegate` tool.
    public func setDelegateHandler(_ handler: @escaping @Sendable (_ child: String, _ task: String) async -> String) {
        self.delegateHandler = handler
    }

    /// Whether the policy permits a tool: the capability must cover its action class,
    /// and the optional allowlist must include it. The model is only *offered* tools
    /// that pass this, and `executeTool` re-checks (defense in depth).
    private func isPermitted(_ name: String) -> Bool {
        let capOK: Bool
        switch name {
        case "read_file", "list_dir": capOK = true
        case "write_file":            capOK = policy.capability != .readOnly
        case "run_command":           capOK = policy.capability == .execute
        case "delegate":              capOK = delegateHandler != nil   // orchestration, not a file/shell tier
        case _ where name.hasPrefix("mcp__"):
            // MCP tools are gated by the per-Node server grant (which servers the
            // Node may reach), not by the file/shell capability tiers.
            return mcpRoute[name] != nil
        default:                      capOK = false
        }
        let allowOK = policy.allowed?.contains(name) ?? true
        return capOK && allowOK
    }

    /// Connect to the granted MCP servers once, aggregating their tools. A server
    /// that fails to connect is skipped; the rest still work. Idempotent.
    private func connectMCPIfNeeded() async {
        guard !mcpConnected else { return }
        mcpConnected = true
        for server in mcpServers {
            let client = MCPStdioClient(server: server, cwd: cwd)
            guard let specs = try? await client.connect() else { continue }
            mcpClients.append(client)
            for spec in specs {
                let emitted = Self.mcpToolName(server: server.name, tool: spec.name)
                mcpRoute[emitted] = (client, spec.name)
                let schema = (try? JSONSerialization.jsonObject(with: spec.inputSchemaJSON)) as? [String: Any]
                    ?? ["type": "object"]
                mcpToolSchemas.append(["type": "function", "function": [
                    "name": emitted,
                    "description": "[\(server.name)] \(spec.description)",
                    "parameters": schema,
                ]])
            }
        }
    }

    /// Namespaced, schema-safe tool name (`^[A-Za-z0-9_-]{1,64}$`).
    private static func mcpToolName(server: String, tool: String) -> String {
        func san(_ s: String) -> String {
            String(s.map { ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        }
        return String("mcp__\(san(server))__\(san(tool))".prefix(64))
    }

    // MARK: - AgentSession

    public func createSession(metadata: [String: String]?) async throws -> String {
        if let sessionId { return sessionId }
        let id = UUID().uuidString
        sessionId = id
        return id
    }

    public func currentCapabilities() async throws -> AgentCapabilities {
        AgentCapabilities(
            workingDirectory: cwd,
            currentModelId: model,
            models: [AgentModel(id: model, name: model, description: "OpenAI-compatible", contextTokens: nil)]
        )
    }

    public func currentUsage() async -> SessionUsage { usage }
    public func cancelCurrentPrompt() async { cancelled = true }
    public func finishCurrentPrompt(for _: String) async { cancelled = true }
    public func terminateSession(sessionId _: String) async { messages.removeAll() }

    // The loop executes tools inline, so these out-of-band channels are unused here
    // (the permission overlay path is grok-specific; API guardrails land in Phase C).
    public func sendToolResult(sessionId _: String, toolCallId _: String, result _: String, isError _: Bool) async throws {}
    public func respondToPermission(permissionId _: String, chosenOption _: String, sessionId _: String) async throws {}
    public func respondToUserQuestion(questionId _: String, questionIndex _: Int, answer _: String) async throws {}

    public func sendPrompt(sessionId sid: String, prompt: String) async throws -> AsyncStream<ACPEvent> {
        cancelled = false
        messages.append(["role": "user", "content": prompt])
        let session = sessionId ?? sid
        return AsyncStream<ACPEvent> { continuation in
            let task = Task {
                await self.runLoop(session: session) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - The agent loop

    private func runLoop(session: String, emit: @Sendable @escaping (ACPEvent) -> Void) async {
        await connectMCPIfNeeded()
        var iteration = 0
        while iteration < maxIterations {
            iteration += 1
            if cancelled { break }

            let response: [String: Any]
            do {
                response = try await callChatCompletions()
            } catch {
                emit(.error(ACPErrorEvent(sessionId: session, code: "backend",
                                          message: "\(model) call failed: \(error.localizedDescription)")))
                emit(.done(sessionId: session))
                return
            }

            if let u = response["usage"] as? [String: Any] {
                usage = SessionUsage(totalTokens: (u["total_tokens"] as? Int) ?? usage.totalTokens,
                                     inputTokens: u["prompt_tokens"] as? Int,
                                     outputTokens: u["completion_tokens"] as? Int)
            }
            guard let choices = response["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                emit(.error(ACPErrorEvent(sessionId: session, code: "backend", message: "malformed response")))
                emit(.done(sessionId: session)); return
            }

            // Keep the assistant message verbatim in history (preserves tool_calls
            // for the follow-up turn that OpenAI's protocol requires).
            messages.append(message)

            if let content = message["content"] as? String, !content.isEmpty {
                emit(.message(MessageEvent(sessionId: session, role: "assistant", content: content, metadata: nil)))
            }

            guard let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
                emit(.done(sessionId: session))   // no tools → turn complete
                return
            }

            for call in toolCalls {
                if cancelled { break }
                let id = call["id"] as? String ?? UUID().uuidString
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? "unknown"
                let argsJSON = fn["arguments"] as? String ?? "{}"
                emit(.toolCall(ToolCallEvent(sessionId: session, toolCallId: id, toolName: name,
                                             arguments: argsPreview(argsJSON))))
                // Design-oracle SHADOW (design/13): the governance engine observes
                // the proposed Action and logs the verdict it *would* reach — it does
                // NOT gate execution yet. The API loop is the high-fidelity boundary
                // (full structured args), so precise detectors run here.
                emit(.activity(ActivityEvent(sessionId: session,
                    note: "oracle(shadow): \(shadowVerdict(name: name, argsJSON: argsJSON).summary)",
                    kind: "oracle_shadow", metadata: nil)))
                let (result, isError) = await executeTool(name: name, argumentsJSON: argsJSON)
                emit(.toolResult(ToolResultEvent(sessionId: session, toolCallId: id, result: result, isError: isError)))
                messages.append(["role": "tool", "tool_call_id": id, "content": result])
            }
            // loop again with the tool results in context
        }
        if iteration >= maxIterations {
            emit(.activity(ActivityEvent(sessionId: session, note: "stopped after \(maxIterations) tool rounds",
                                         kind: "limit", metadata: nil)))
        }
        emit(.done(sessionId: session))
    }

    private func callChatCompletions() async throws -> [String: Any] {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw NSError(domain: "OpenAICompat", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad baseURL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 120
        // Only offer the model the tools its policy permits, plus the bridged MCP
        // tools (already gated by the per-Node server grant).
        var tools = Self.toolSchemas.filter { schema in
            guard let fn = schema["function"] as? [String: Any], let name = fn["name"] as? String else { return false }
            return isPermitted(name)
        }
        tools.append(contentsOf: mcpToolSchemas)
        let body: [String: Any] = [
            "model": model, "messages": messages, "tools": tools,
            "tool_choice": "auto", "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw NSError(domain: "OpenAICompat", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(detail)"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OpenAICompat", code: -2, userInfo: [NSLocalizedDescriptionKey: "non-JSON response"])
        }
        return obj
    }

    private func argsPreview(_ json: String) -> [String: String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return obj.mapValues { "\($0)" }
    }

    /// Build a `ProposedAction` from this tool call and run it through the shadow
    /// governance engine (design/13). Observation only — the returned `Verdict` is
    /// logged, never enforced (that is the oracle's v1).
    private func shadowVerdict(name: String, argsJSON: String) -> Verdict {
        var server: String?, tool: String?
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")   // server__tool
            if parts.count >= 2 { server = parts.first; tool = parts.dropFirst().joined(separator: "__") }
        }
        let action = ProposedAction.fromAPITool(name: name, arguments: argsPreview(argsJSON),
                                                cwd: cwd, nodeName: nil, mcpServer: server, mcpTool: tool)
        return GovernanceEngine.shadow.evaluate(action)
    }

    // MARK: - Tools (app-executed, cwd-scoped)

    private static var toolSchemas: [[String: Any]] { [
        toolSchema("read_file", "Read a UTF-8 text file. Path is relative to the working directory.",
                   ["path": ["type": "string"]], ["path"]),
        toolSchema("list_dir", "List the entries of a directory (relative to the working directory; default '.').",
                   ["path": ["type": "string"]], []),
        toolSchema("write_file", "Write (overwrite) a UTF-8 text file, relative to the working directory.",
                   ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        toolSchema("run_command", "Run a shell command in the working directory and return combined stdout/stderr.",
                   ["command": ["type": "string"]], ["command"]),
        toolSchema("delegate", "Delegate a sub-task to one of your child agents and return its result. "
                   + "`child` is the child agent's name; `task` is what to ask it.",
                   ["child": ["type": "string"], "task": ["type": "string"]], ["child", "task"]),
    ] }

    private static func toolSchema(_ name: String, _ desc: String,
                                   _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": desc,
            "parameters": ["type": "object", "properties": props, "required": required],
        ]]
    }

    /// Resolve a tool path under cwd; returns nil if it escapes (basic policy).
    private func resolved(_ path: String?) -> String? {
        let p = (path ?? ".").trimmingCharacters(in: .whitespaces)
        let base = URL(fileURLWithPath: cwd)
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appendingPathComponent(p)
        let std = url.standardizedFileURL.path
        return std == base.path || std.hasPrefix(base.path + "/") ? std : nil
    }

    private func executeTool(name: String, argumentsJSON: String) async -> (String, Bool) {
        guard isPermitted(name) else { return ("denied by policy: \(name) is not permitted for this node", true) }
        // Bridged MCP tool → proxy to its server's client.
        if name.hasPrefix("mcp__"), let route = mcpRoute[name] {
            return await route.client.call(route.tool, argumentsJSON: argumentsJSON)
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "read_file":
            guard let path = resolved(args["path"] as? String) else { return ("denied: path outside working directory", true) }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ("error: cannot read \(path)", true) }
            return (cap(text), false)
        case "list_dir":
            guard let path = resolved(args["path"] as? String) else { return ("denied: path outside working directory", true) }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return ("error: cannot list \(path)", true) }
            return (cap(items.sorted().joined(separator: "\n")), false)
        case "write_file":
            guard let path = resolved(args["path"] as? String) else { return ("denied: path outside working directory", true) }
            let content = args["content"] as? String ?? ""
            do { try content.write(toFile: path, atomically: true, encoding: .utf8); return ("wrote \(content.utf8.count) bytes", false) }
            catch { return ("error: \(error.localizedDescription)", true) }
        case "run_command":
            guard let command = args["command"] as? String else { return ("error: missing command", true) }
            return await Self.runCommand(command, cwd: cwd, cap: outputCap)
        case "delegate":
            guard let handler = delegateHandler else { return ("delegation not available for this node", true) }
            let child = args["child"] as? String ?? ""
            let task = args["task"] as? String ?? ""
            return (await handler(child, task), false)
        default:
            return ("error: unknown tool \(name)", true)
        }
    }

    private func cap(_ s: String) -> String {
        guard s.count > outputCap else { return s }
        return String(s.prefix(outputCap)) + "\n…[truncated, \(s.count - outputCap) more chars]"
    }

    private static func runCommand(_ command: String, cwd: String, cap: Int) async -> (String, Bool) {
        final class Box: @unchecked Sendable { let p = Process() }
        let box = Box()
        return await Task.detached(priority: .userInitiated) { [box] () -> (String, Bool) in
            let p = box.p
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            p.environment = LoginShellEnvironment.shared
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return ("error: \(error.localizedDescription)", true) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var out = String(data: data, encoding: .utf8) ?? ""
            if out.count > cap { out = String(out.prefix(cap)) + "\n…[truncated]" }
            return (out.isEmpty ? "(no output, exit \(p.terminationStatus))" : out, p.terminationStatus != 0)
        }.value
    }
}
