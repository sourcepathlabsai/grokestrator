import Foundation
import GrokestratorCore

/// High-level client for one running Grok Build instance, speaking real ACP
/// (newline-delimited JSON-RPC 2.0) over stdio.
///
/// Responsibilities:
/// - lazily `initialize` + `session/new` (one session per instance for now),
/// - run `session/prompt` and translate streamed `session/update` notifications
///   into the internal `ACPEvent` stream the rest of the black box consumes,
/// - service agent→client requests: surface `session/request_permission` to the user
///   and perform `fs/read_text_file` / `fs/write_text_file`.
public actor GrokBuildSessionClient {
    private let handle: GrokBuildInstanceHandle
    private let reader: ACPMessageReader

    private var nextId = 1
    private var pending: [RPCID: CheckedContinuation<Data, Error>] = [:]
    /// Agent→client permission requests awaiting the user's choice (permissionId → JSON-RPC id).
    private var pendingPermissions: [String: RPCID] = [:]
    /// Agent→client user-question requests (`_x.ai/ask_user_question`) awaiting the
    /// user's answer (questionId → JSON-RPC id). Parallels `pendingPermissions`.
    private var pendingQuestions: [String: RPCID] = [:]

    private var initialized = false
    private var sessionId: String?

    /// What this instance can do (model, MCP servers, slash commands), captured
    /// from the `initialize` result and refreshed by `available_commands_update`.
    /// Drives the Instance Inspector and the composer's slash-command popup.
    private var capabilities = AgentCapabilities.empty

    /// Permission categories the user chose "always allow" for, this session
    /// (e.g. "Bash"). grok re-asks even after `allow_always`, so once the user has
    /// blessed a category we answer matching requests ourselves. Per-session: a
    /// fresh process starts with an empty set.
    private var alwaysAllowCategories: Set<String> = []
    /// Per-pending-permission memo, so we can learn the user's choice when it returns.
    private var permissionMemos: [String: PermissionMemo] = [:]
    private struct PermissionMemo { let category: String?; let optionKinds: [String: String] }

    /// Token / context-window usage, updated live from `session/update._meta` and
    /// finalized from the `session/prompt` result `_meta`.
    private var usage = SessionUsage.empty

    // Active prompt streaming + chunk coalescing.
    private var activeStream: AsyncStream<ACPEvent>.Continuation?
    private var thoughtBuffer = ""
    private var messageBuffer = ""

    /// Timestamp of the last sign of life for the active turn. The prompt watchdog
    /// (see `armIdleWatchdog`) measures silence against this; any session/update,
    /// agent request, or permission answer refreshes it.
    private var lastActivity = Date()
    /// A turn is failed only after this much *total* silence — and never while a
    /// permission request is pending (the user may answer days later).
    private static let promptIdleLimit: TimeInterval = 30 * 60

    private var readerTask: Task<Void, Never>?

    public init(handle: GrokBuildInstanceHandle) {
        self.handle = handle
        self.reader = ACPMessageReader(dataStream: handle.stdout)
        // Start the reader once the actor is fully initialized.
        Task { await self.startReader() }
    }

    private func startReader() {
        readerTask = Task { [reader] in
            for await line in await reader.lines() {
                await self.handleLine(line)
            }
            self.handleDisconnect()
        }
    }

    // MARK: - Public API (compatible with the existing black box)

    /// Ensures the instance is initialized + has a session, returning the session id.
    @discardableResult
    public func createSession(metadata: [String: String]? = nil) async throws -> String {
        try await ensureSession()
    }

    /// The instance's capabilities (model, MCP servers, slash commands). Ensures
    /// the session exists first so `initialize` (and its `available_commands_update`
    /// follow-up) have run — making this safe to call before the first prompt.
    public func currentCapabilities() async throws -> AgentCapabilities {
        _ = try await ensureSession()
        return capabilities
    }

    /// Current token / context usage (running totals + last turn's breakdown).
    /// Fills the context window from the captured model so callers can show a %.
    public func currentUsage() -> SessionUsage {
        var u = usage
        u.contextWindow = capabilities.currentModel?.contextTokens
        return u
    }

    /// Sends a prompt and returns a stream of high-level `ACPEvent`s for the turn.
    /// The `sessionId` argument is accepted for source compatibility but ignored —
    /// the client manages its own (single) ACP session.
    public func sendPrompt(sessionId _: String, prompt: String) async throws -> AsyncStream<ACPEvent> {
        let sid = try await ensureSession()

        let (stream, continuation) = AsyncStream<ACPEvent>.makeStream(bufferingPolicy: .unbounded)
        activeStream?.finish()
        activeStream = continuation
        thoughtBuffer = ""
        messageBuffer = ""
        noteActivity()

        Task {
            do {
                // No hard timeout: an agent turn can run for many minutes and may
                // pause for *days* on a permission prompt. An idle watchdog guards
                // against a truly dead connection instead (see `armIdleWatchdog`).
                let result = try await self.request(
                    method: "session/prompt",
                    params: .object([
                        "sessionId": .string(sid),
                        "prompt": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
                    ]),
                    as: PromptStopResult.self,
                    timeout: nil
                )
                self.completePrompt(result: result)
            } catch {
                self.failPrompt(error)
            }
        }

        return stream
    }

    /// No-op under ACP: the agent executes tools itself (asking us for permission
    /// and file access). Kept for source compatibility with the black box.
    public func sendToolResult(sessionId _: String, toolCallId _: String, result _: String, isError _: Bool = false) async throws {}

    /// Stops the current turn. Sends a best-effort `session/cancel` notification
    /// to grok (the server may or may not honor it on this version), then
    /// **locally** finishes the active stream so the conversation's awaiting
    /// for-loop unwinds and broadcasts `turnComplete`. Spinner clears
    /// immediately even if grok keeps streaming briefly — those late updates
    /// land on a nil `activeStream` and are harmlessly dropped.
    public func cancelCurrentPrompt() async {
        if let sid = sessionId {
            write(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/cancel"),
                "params": .object(["sessionId": .string(sid)]),
            ]))
        }
        activeStream?.finish()
        activeStream = nil
        thoughtBuffer = ""
        messageBuffer = ""
    }

    /// Resolves a pending permission request with the chosen ACP `optionId`.
    public func respondToPermission(permissionId: String, chosenOption: String, sessionId _: String) async throws {
        guard let id = pendingPermissions.removeValue(forKey: permissionId) else { return }
        // Learn: if the user picked an "allow always" option, remember this category
        // so future matching requests are answered without bothering them again.
        if let memo = permissionMemos.removeValue(forKey: permissionId),
           let category = memo.category, memo.optionKinds[chosenOption] == "allow_always" {
            alwaysAllowCategories.insert(category)
        }
        // Answering revives the turn: refresh the idle clock so the watchdog gives
        // grok a full window to resume before considering the connection stalled.
        noteActivity()
        respond(id: id, result: selectedOutcome(chosenOption))
        // Tell every subscriber this is answered so other devices clear the overlay.
        emit(.interactionResolved(InteractionResolvedEvent(sessionId: sessionId ?? "", id: permissionId)))
    }

    /// Resolves a pending `_x.ai/ask_user_question` request with the user's answer.
    /// `answer` is either a chosen option's label or free text (the "Other" path);
    /// both are returned to the agent as the label string for the given question.
    public func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async throws {
        guard let id = pendingQuestions.removeValue(forKey: questionId) else { return }
        // Answering revives the turn: refresh the idle clock so the watchdog gives
        // grok a full window to resume before considering the connection stalled.
        noteActivity()
        // NOTE: The exact result shape grok expects for `_x.ai/ask_user_question`
        // is UNVERIFIED — we have wire logs for the request but not the reply. This
        // is a reasonable guess and MAY NEED ADJUSTMENT after live testing. We send
        // a structured per-question answer carrying both the index and the label.
        respond(id: id, result: .object([
            "selectedOptions": .array([
                .object([
                    "optionIndex": .int(questionIndex),
                    "label": .string(answer),
                ])
            ])
        ]))
        // Tell every subscriber this is answered so other devices clear the overlay.
        emit(.interactionResolved(InteractionResolvedEvent(sessionId: sessionId ?? "", id: questionId)))
    }

    /// Finishes the active prompt stream early.
    public func finishCurrentPrompt(for _: String) {
        activeStream?.finish()
        activeStream = nil
    }

    public func terminateSession(sessionId _: String) async {
        activeStream?.finish()
        activeStream = nil
    }

    // MARK: - Session setup

    private func ensureSession() async throws -> String {
        if let sessionId { return sessionId }

        var cwd = FileManager.default.currentDirectoryPath
        if !initialized {
            let initResult = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .int(1),
                    "clientCapabilities": .object([
                        "fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(true)]),
                        "terminal": .bool(false),
                    ]),
                ]),
                as: InitializeResult.self,
                timeout: 30
            )
            cwd = initResult.meta?.currentWorkingDirectory ?? cwd
            capabilities = initResult.toCapabilities()
            capabilities.commands = GrokBuiltinCommands.merged(advertised: capabilities.commands)
            initialized = true
        }

        let result = try await request(
            method: "session/new",
            params: .object(["cwd": .string(cwd), "mcpServers": .array([])]),
            as: NewSessionResult.self,
            timeout: 30
        )
        sessionId = result.sessionId
        return result.sessionId
    }

    // MARK: - Incoming line routing

    private func handleLine(_ line: Data) async {
        guard let env = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else { return }

        if let method = env.method, let id = env.id {
            await handleAgentRequest(method: method, id: id, line: line)
        } else if let method = env.method {
            handleNotification(method: method, line: line)
        } else if let id = env.id, let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: line)
        }
    }

    private func handleNotification(method: String, line: Data) {
        // grok's vendor MCP lifecycle notifications → live aggregate MCP status
        // for the Instance Inspector (servers come up async after the handshake).
        switch method {
        case "_x.ai/mcp/init_progress":
            if let p = try? JSONDecoder().decode(RPCParams<MCPInitProgress>.self, from: line).params {
                capabilities.mcpTotal = p.total ?? capabilities.mcpTotal
                capabilities.mcpConnected = p.connected ?? capabilities.mcpConnected
            }
            return
        case "_x.ai/mcp_initialized":
            if let p = try? JSONDecoder().decode(RPCParams<MCPInitialized>.self, from: line).params {
                capabilities.mcpToolCount = p.mcpToolCount
                if let total = capabilities.mcpTotal { capabilities.mcpConnected = total }
            }
            return
        default:
            break
        }

        guard method == "session/update",
              let p = try? JSONDecoder().decode(RPCParams<SessionUpdateParams>.self, from: line).params
        else { return } // ignore other vendor _x.ai/* notifications for now

        noteActivity()   // the turn is alive — refresh the idle watchdog
        if let t = p.meta?.totalTokens { usage.totalTokens = t }   // running context usage
        let sid = p.sessionId
        switch p.update.sessionUpdate {
        case "agent_thought_chunk":
            if !messageBuffer.isEmpty { flushMessage(sid) }
            if let t = p.update.content?.text {
                thoughtBuffer += t
                emit(.thoughtDelta(t))   // live streaming
            }

        case "agent_message_chunk":
            if !thoughtBuffer.isEmpty { flushThought(sid) }
            if let t = p.update.content?.text {
                messageBuffer += t
                emit(.messageDelta(t))   // live streaming
            }

        case "tool_call":
            flushThought(sid); flushMessage(sid)
            let name = p.update.title ?? p.update.kind ?? "tool"
            emit(.toolCall(ToolCallEvent(sessionId: sid, toolCallId: p.update.toolCallId ?? UUID().uuidString, toolName: name, arguments: nil)))

        case "tool_call_update":
            if let status = p.update.status {
                emit(.activity(ActivityEvent(sessionId: sid, note: "\(p.update.title ?? "tool") — \(status)", kind: "tool_update", metadata: nil)))
            }

        case "available_commands_update":
            // The authoritative, possibly-updating advertised list (plugins can change
            // it), merged with the documented built-in catalog for discoverability.
            if let cmds = p.update.availableCommands {
                let advertised = cmds.map { SlashCommand(name: $0.name, description: $0.description, hint: $0.input?.hint) }
                capabilities.commands = GrokBuiltinCommands.merged(advertised: advertised)
            }

        case "plan":
            // grok re-broadcasts the ENTIRE plan on every status change. Map the
            // raw wire entries to the Core model, normalizing unknown
            // priority/status strings defensively (never crash on a new value).
            let entries = (p.update.entries ?? []).map { wire in
                AgentPlan.Entry(
                    content: wire.content,
                    priority: AgentPlan.Entry.Priority(rawValue: wire.priority ?? "") ?? .medium,
                    status: AgentPlan.Entry.Status(rawValue: wire.status ?? "") ?? .pending
                )
            }
            emit(.plan(PlanEvent(sessionId: sid, plan: AgentPlan(entries: entries))))

        case "current_mode_update":
            // ACP standard carries `currentModeId`. grok hasn't been observed to
            // emit this, so we don't build UI for it — just stop dropping it
            // silently: leave a low-key activity note if a mode id is present.
            if let mode = p.update.currentModeId {
                emit(.activity(ActivityEvent(sessionId: sid, note: "mode: \(mode)", kind: "mode", metadata: nil)))
            }

        default:
            emit(.activity(ActivityEvent(sessionId: sid, note: p.update.sessionUpdate, kind: "update", metadata: nil)))
        }
    }

    private func handleAgentRequest(method: String, id: RPCID, line: Data) async {
        noteActivity()   // an agent→client request is a sign of life
        switch method {
        case "session/request_permission":
            guard let p = try? JSONDecoder().decode(RPCParams<PermissionParams>.self, from: line).params, !p.options.isEmpty else {
                respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
                return
            }
            // If the user already chose "always allow" for this category (e.g. bash),
            // answer it ourselves — grok re-asks even after `allow_always`.
            if let category = p.category, alwaysAllowCategories.contains(category),
               let allow = p.options.first(where: { $0.kind == "allow_always" }) ?? p.options.first(where: { $0.kind == "allow_once" }) {
                respond(id: id, result: selectedOutcome(allow.optionId))
                emit(.activity(ActivityEvent(
                    sessionId: p.sessionId ?? sessionId ?? "",
                    note: "Auto-approved (\(category), remembered): \(p.toolCall?.title ?? "permission")",
                    kind: "permission_auto", metadata: nil)))
                return
            }
            // Suspend the request: keep its JSON-RPC id pending and surface it to the
            // user. `respondToPermission` resolves it once the user chooses; the memo
            // lets us learn an allow-always choice when it comes back.
            let permissionId = idString(id)
            pendingPermissions[permissionId] = id
            permissionMemos[permissionId] = PermissionMemo(
                category: p.category,
                optionKinds: Dictionary(p.options.map { ($0.optionId, $0.kind ?? "") }, uniquingKeysWith: { a, _ in a })
            )
            let options = p.options.map { PermissionOption(id: $0.optionId, label: $0.name ?? $0.optionId, kind: $0.kind) }
            emit(.permissionRequest(PermissionRequestEvent(
                sessionId: p.sessionId ?? sessionId ?? "",
                permissionId: permissionId,
                description: p.toolCall?.title ?? "Grok is requesting permission.",
                options: options
            )))

        case "_x.ai/ask_user_question":
            guard let p = try? JSONDecoder().decode(RPCParams<AskUserQuestionParams>.self, from: line).params,
                  !p.questions.isEmpty else {
                respondError(id, "invalid _x.ai/ask_user_question params"); return
            }
            // Suspend the request: keep its JSON-RPC id pending and surface it to the
            // user, exactly as `session/request_permission` does. `respondToUserQuestion`
            // resolves it once the user answers.
            let questionId = idString(id)
            pendingQuestions[questionId] = id
            let questions = p.questions.map { q in
                UserQuestion(prompt: q.question, options: q.options.map {
                    UserQuestionOption(label: $0.label, description: $0.description)
                })
            }
            emit(.userQuestion(UserQuestionEvent(
                sessionId: p.sessionId ?? sessionId ?? "",
                questionId: questionId,
                questions: questions
            )))

        case "fs/read_text_file":
            guard let p = try? JSONDecoder().decode(RPCParams<FsReadParams>.self, from: line).params else {
                respondError(id, "invalid fs/read_text_file params"); return
            }
            respond(id: id, result: .object(["content": .string(readFile(p))]))
            emit(.activity(ActivityEvent(sessionId: p.sessionId, note: "read \(p.path)", kind: "fs", metadata: nil)))

        case "fs/write_text_file":
            guard let p = try? JSONDecoder().decode(RPCParams<FsWriteParams>.self, from: line).params else {
                respondError(id, "invalid fs/write_text_file params"); return
            }
            try? p.content.write(toFile: p.path, atomically: true, encoding: .utf8)
            respond(id: id, result: .null)
            emit(.activity(ActivityEvent(sessionId: p.sessionId, note: "wrote \(p.path)", kind: "fs", metadata: nil)))

        default:
            respondError(id, "method not handled: \(method)")
        }
    }

    private func readFile(_ p: FsReadParams) -> String {
        guard let full = try? String(contentsOfFile: p.path, encoding: .utf8) else { return "" }
        if p.line == nil && p.limit == nil { return full }
        var lines = full.components(separatedBy: "\n")
        let start = max((p.line ?? 1) - 1, 0)
        lines = start < lines.count ? Array(lines[start...]) : []
        if let limit = p.limit, limit < lines.count { lines = Array(lines[0..<limit]) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt completion / streaming helpers

    private func completePrompt(result: PromptStopResult) {
        if let m = result.meta { updateUsage(from: m) }
        let sid = sessionId ?? ""
        flushThought(sid)
        flushMessage(sid)
        activeStream?.yield(.done(sessionId: sid))
        activeStream?.finish()
        activeStream = nil
    }

    private func failPrompt(_ error: Error) {
        activeStream?.yield(.error(ACPErrorEvent(sessionId: sessionId, code: "prompt_failed", message: error.localizedDescription)))
        activeStream?.finish()
        activeStream = nil
    }

    private func flushThought(_ sid: String) {
        guard !thoughtBuffer.isEmpty else { return }
        emit(.thought(ThoughtEvent(sessionId: sid, content: thoughtBuffer, metadata: nil)))
        thoughtBuffer = ""
    }

    private func flushMessage(_ sid: String) {
        guard !messageBuffer.isEmpty else { return }
        emit(.message(MessageEvent(sessionId: sid, role: "assistant", content: messageBuffer, metadata: nil)))
        messageBuffer = ""
    }

    private func emit(_ event: ACPEvent) {
        activeStream?.yield(event)
    }

    private func handleDisconnect() {
        for (_, cont) in pending { cont.resume(throwing: GrokBuildError.protocolError("ACP connection closed")) }
        pending.removeAll()
        activeStream?.finish()
        activeStream = nil
    }

    // MARK: - JSON-RPC request/response plumbing

    /// Issues a JSON-RPC request. `timeout` is a fixed wall-clock deadline for
    /// fast handshake calls (`initialize`, `session/new`). Pass `nil` for calls
    /// that legitimately run long or pause on user input (`session/prompt`); those
    /// are instead guarded by the activity-aware idle watchdog.
    private func request<T: Decodable>(method: String, params: JSONValue, as _: T.Type, timeout: Double?) async throws -> T {
        let id = RPCID.int(nextId); nextId += 1

        let line: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            write(.object(["jsonrpc": .string("2.0"), "id": id.jsonValue, "method": .string(method), "params": params]))
            if let timeout {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.timeoutPending(id, method: method)
                }
            } else {
                armIdleWatchdog(id: id, method: method)
            }
        }

        if let env = try? JSONDecoder().decode(RPCEnvelope.self, from: line), let err = env.error {
            throw GrokBuildError.protocolError("\(method) failed: \(err.message) (\(err.code))")
        }
        return try JSONDecoder().decode(RPCResult<T>.self, from: line).result
    }

    private func timeoutPending(_ id: RPCID, method: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: GrokBuildError.protocolError("\(method) timed out"))
        }
    }

    private func noteActivity() { lastActivity = Date() }

    /// The JSON-RPC result body for a chosen permission option.
    private func selectedOutcome(_ optionId: String) -> JSONValue {
        .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionId)])])
    }

    /// Folds a turn's token breakdown into `usage` (keeping a non-zero running total).
    private func updateUsage(from m: TokenMeta) {
        if let t = m.totalTokens, t > 0 { usage.totalTokens = t }
        if let v = m.inputTokens { usage.inputTokens = v }
        if let v = m.outputTokens { usage.outputTokens = v }
        if let v = m.cachedReadTokens { usage.cachedReadTokens = v }
        if let v = m.reasoningTokens { usage.reasoningTokens = v }
    }

    /// Watches an in-flight long-running request (the prompt). It fails the request
    /// only after `promptIdleLimit` of *total* silence, and **never** while a
    /// permission request is pending — so a turn left waiting on the user (minutes
    /// or days) is preserved, while a genuinely dead connection still gets cleaned up.
    private func armIdleWatchdog(id: RPCID, method: String) {
        Task {
            while self.idleCheck(id: id, method: method) == false {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)   // re-check each minute
            }
        }
    }

    /// One watchdog tick. Returns `true` when the watchdog should stop (request
    /// resolved or failed), `false` to keep watching.
    private func idleCheck(id: RPCID, method: String) -> Bool {
        guard pending[id] != nil else { return true }   // already resolved → done
        if !pendingPermissions.isEmpty || !pendingQuestions.isEmpty {
            noteActivity()                                // paused on the user; don't age out
            return false
        }
        guard Date().timeIntervalSince(lastActivity) > Self.promptIdleLimit else { return false }
        if let cont = pending.removeValue(forKey: id) {
            let mins = Int(Self.promptIdleLimit / 60)
            cont.resume(throwing: GrokBuildError.protocolError("\(method) stalled (no activity for \(mins)m)"))
        }
        return true
    }

    private func respond(id: RPCID, result: JSONValue) {
        write(.object(["jsonrpc": .string("2.0"), "id": id.jsonValue, "result": result]))
    }

    private func respondError(_ id: RPCID, _ message: String) {
        write(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .object(["code": .int(-32603), "message": .string(message)]),
        ]))
    }

    /// Encodes a JSON-RPC message and writes it as a single newline-terminated line.
    /// Uses `.withoutEscapingSlashes` — Grok rejects slash-escaped method names.
    private func write(_ value: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        var line = data
        line.append(0x0A)
        try? handle.stdin.write(contentsOf: line)
    }
}

private extension RPCID {
    var jsonValue: JSONValue {
        switch self {
        case .int(let i): return .int(i)
        case .string(let s): return .string(s)
        }
    }
}

private extension GrokBuildSessionClient {
    nonisolated func idString(_ id: RPCID) -> String {
        switch id {
        case .int(let i): return "rpc-\(i)"
        case .string(let s): return s
        }
    }
}

/// `_x.ai/mcp/init_progress` params — servers connecting (`connected` of `total`).
private struct MCPInitProgress: Decodable { let total: Int?; let connected: Int? }
/// `_x.ai/mcp_initialized` params — MCP load finished; total tools across servers.
private struct MCPInitialized: Decodable { let mcpToolCount: Int?; let elapsedMs: Int? }

/// Decode of the `initialize` result `_meta` — cwd plus the capability data the
/// inspector / slash popup surface (model, MCP servers, slash commands).
/// Verified against `grok 0.2.3` (see PROJECT_STATE / probe notes).
private struct InitializeResult: Decodable {
    let meta: Meta?
    enum CodingKeys: String, CodingKey { case meta = "_meta" }

    struct Meta: Decodable {
        let agentVersion: String?
        let currentWorkingDirectory: String?
        let modelState: ModelState?
        let mcpServers: [MCPServer]?
        let availableCommands: [CommandWire]?
    }

    struct ModelState: Decodable {
        let currentModelId: String?
        let availableModels: [Model]?
    }

    struct Model: Decodable {
        let modelId: String
        let name: String?
        let description: String?
        let meta: ModelMeta?
        enum CodingKeys: String, CodingKey { case modelId, name, description, meta = "_meta" }
        struct ModelMeta: Decodable { let totalContextTokens: Int? }
    }

    /// We intentionally decode only identity + transport — never `args`/`env`,
    /// which carry plaintext secrets in grok's config.
    struct MCPServer: Decodable {
        let name: String?
        let type: String?
        let command: String?
    }

    func toCapabilities() -> AgentCapabilities {
        let models = (meta?.modelState?.availableModels ?? []).map {
            AgentModel(id: $0.modelId, name: $0.name, description: $0.description, contextTokens: $0.meta?.totalContextTokens)
        }
        let servers = (meta?.mcpServers ?? []).enumerated().map { idx, s in
            MCPServerInfo(id: s.name ?? "\(s.command ?? "server")-\(idx)", name: s.name, type: s.type, command: s.command)
        }
        let commands = (meta?.availableCommands ?? []).map {
            SlashCommand(name: $0.name, description: $0.description, hint: $0.input?.hint)
        }
        return AgentCapabilities(
            agentVersion: meta?.agentVersion,
            workingDirectory: meta?.currentWorkingDirectory,
            currentModelId: meta?.modelState?.currentModelId,
            models: models,
            mcpServers: servers,
            commands: commands
        )
    }
}
