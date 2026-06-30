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
    /// ACP `agentInfo` + auth hint captured at `initialize`, used to give a clear
    /// "needs login" message when `session/new` fails for an unauthenticated agent.
    private var agentDisplayName: String?
    private var authHint: String?

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

    /// Image artifact paths already surfaced as inline images (image_gen/image_edit),
    /// so a re-sent `completed` tool update doesn't render the same image twice.
    private var renderedImagePaths: Set<String> = []

    /// The node's resolved working directory + the governance engine built from its project
    /// oracle (`<cwd>/design/oracle/`). Built once the cwd is known (after `initialize`);
    /// falls back to the baseline engine until then.
    private var workingDirectory: String?
    private var governance: GovernanceEngine?

    /// Per-Node auto-approval policy for ACP tool prompts (default: ask for
    /// everything). Captured at construction; an edit restarts the Node → new client.
    private let autoApproval: AutoApproval
    private let oracleEnforcement: OracleEnforcement

    public init(handle: GrokBuildInstanceHandle, autoApproval: AutoApproval = .manual,
                oracleEnforcement: OracleEnforcement = .shadow) {
        self.handle = handle
        self.autoApproval = autoApproval
        self.oracleEnforcement = oracleEnforcement
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

        // The Connection's configured working directory is AUTHORITATIVE — an ACP adapter
        // (e.g. Claude Code) that doesn't self-report a cwd must use this, not the GUI app's
        // "/" cwd. grok reports the same dir it was launched in, so they agree for grok.
        var cwd = handle.workingDirectory ?? FileManager.default.currentDirectoryPath
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
            // Configured dir wins; only fall back to the agent-reported cwd, then the app cwd.
            cwd = handle.workingDirectory ?? initResult.meta?.currentWorkingDirectory ?? cwd
            capabilities = initResult.toCapabilities()
            capabilities.commands = GrokBuiltinCommands.merged(advertised: capabilities.commands)
            // Remember how this agent identifies + how to authenticate, so a failed
            // session/new can say "Claude Code needs login" instead of timing out.
            agentDisplayName = initResult.agentInfo?.title ?? initResult.agentInfo?.name
            authHint = (initResult.authMethods ?? []).compactMap { $0.description ?? $0.name }.first
            initialized = true
        }

        // Now the working directory is known — build this node's project-oracle engine
        // (`<cwd>/design/oracle/`, merged over the baseline) for the shadow governance pass.
        workingDirectory = cwd
        governance = GovernanceEngine.forProject(directory: cwd)
        // Show the AUTHORITATIVE session cwd (what we send in `session/new`) in the
        // inspector — not the agent's `initialize` self-report, which precedes session/new
        // and reads "/" for an adapter that doesn't report a cwd (e.g. Claude Code).
        capabilities.workingDirectory = cwd

        // Advertise the in-app Orchestration MCP server (host-local, loopback) so
        // this Node can `delegate` to children. Per-session injection — no config
        // files. Shape verified against grok 0.2.22: name + type:"http" + url +
        // headers (array, required). See design/11-orchestration-platform.md.
        var mcpServers: [JSONValue] = []
        if OrchestrationMCPServer.isActive {
            // Tag the session with this Node's id (grok forwards the header on
            // every MCP request) so the server can scope `delegate` to *this*
            // orchestrator's own children. Header shape {name,value} verified.
            mcpServers.append(.object([
                "name": .string("grokestrator"),
                "type": .string("http"),
                "url": .string(OrchestrationMCPServer.url(port: OrchestrationMCPServer.defaultPort)),
                "headers": .array([.object([
                    "name": .string(OrchestrationMCPServer.nodeHeader),
                    "value": .string(handle.id.uuidString),
                ])]),
            ]))
        }
        // Advertise the host MCP registry servers this Node is granted (Grokestrator
        // owns the registry; the grant filters it — see `MCPRegistry`). Read fresh so
        // registry/grant edits apply on the next session. grok connects to each as a
        // normal MCP client; its tools then appear over ACP like any other.
        let grant = ConnectionStore.load().first { $0.id == handle.id }?.grantedMCPServerIDs
        for server in ConnectionStore.loadMCPRegistry().granted(to: grant) {
            switch server.transport {
            case .stdio(let command, let args, let env):
                mcpServers.append(.object([
                    "name": .string(server.name),
                    "command": .string(command),
                    "args": .array(args.map { .string($0) }),
                    "env": .array(env.map { .object(["name": .string($0.key), "value": .string($0.value)]) }),
                ]))
            case .http(let url, let headers):
                mcpServers.append(.object([
                    "name": .string(server.name),
                    "type": .string("http"),
                    "url": .string(url),
                    "headers": .array(headers.map { .object(["name": .string($0.key), "value": .string($0.value)]) }),
                ]))
            }
        }

        do {
            let result = try await request(
                method: "session/new",
                params: .object(["cwd": .string(cwd), "mcpServers": .array(mcpServers)]),
                as: NewSessionResult.self,
                timeout: 30
            )
            sessionId = result.sessionId
            return result.sessionId
        } catch {
            // An ACP agent that advertised auth methods and then refused/stalled the
            // session is almost certainly not logged in — surface the actionable hint
            // rather than a bare timeout (e.g. Claude Code → "Run `claude /login`").
            if let authHint {
                throw GrokBuildError.instanceManagementError(
                    "\(agentDisplayName ?? "This agent") needs authentication — \(authHint).")
            }
            throw error
        }
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
            // Image tools (`image_gen` / `image_edit`) save the result to grok's session
            // folder and report the path in `rawOutput.path` — and instruct grok's own
            // model NOT to re-display it (grok's native GUI renders it from the folder).
            // Over ACP *we* are the GUI: surface the path as an inline image. Emitting it
            // as a one-line Markdown image reuses the existing ContentParser → image-view
            // path (and persists/replays identically). See design/08 media rendering.
            if let path = Self.imageResultPath(in: line),
               renderedImagePaths.insert(path).inserted {   // once per artifact, even if re-sent
                let alt = (path as NSString).lastPathComponent
                emit(.message(MessageEvent(sessionId: sid, role: "assistant",
                                           content: "![\(alt)](\(path))", metadata: nil)))
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
            // Design-oracle SHADOW (design/13): observe every permission request and
            // log (NSLog, NOT the transcript) the verdict the governance engine *would*
            // reach — it does NOT change who answers (always-allow / auto-approval /
            // human, below, are untouched). This is the low-fidelity boundary: a coarse
            // `kind` + a command/title string, no general structured args — so precise
            // detectors abstain here.
            let action = ProposedAction.fromACPPermission(
                kind: p.toolCall?.kind, variant: p.toolCall?.rawInput?.variant,
                command: p.toolCall?.rawInput?.command, title: p.toolCall?.title,
                agentName: agentDisplayName, cwd: workingDirectory, nodeName: nil)
            let shadow = (governance ?? .shadow).evaluate(action)
            let oracleEnforced = oracleEnforcement == .active && shadow.outcome != .allow
            OracleLedger.shared.record(GovernanceEvent(action: action, verdict: shadow, nodeID: handle.id, at: Date(), enforced: oracleEnforced))
            NSLog("%@", "[oracle] \(oracleEnforcement == .active ? "enforce" : "shadow") (acp): \(shadow.summary)")
            // Oracle enforcement (design/13, Slice 3): when active, `.block` auto-rejects
            // and `.escalate` skips auto-approval so the human sees the prompt.
            if oracleEnforcement == .active {
                if shadow.outcome == .block {
                    // Fail CLOSED: reject via an explicit option if the agent offered one,
                    // else cancel the request outright — a block must NEVER fall through to
                    // the always-allow / auto-approval / manual path below.
                    if let reject = p.options.first(where: { $0.kind == "reject_once" })
                                 ?? p.options.first(where: { $0.kind == "reject_always" }) {
                        respond(id: id, result: selectedOutcome(reject.optionId))
                    } else {
                        respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
                    }
                    emit(.activity(ActivityEvent(
                        sessionId: p.sessionId ?? sessionId ?? "",
                        note: "Oracle blocked: \(String(shadow.rationale.prefix(80)))",
                        kind: "permission_oracle_block", metadata: nil)))
                    return
                }
                if shadow.outcome == .escalate {
                    // Force human review — skip auto-approval, go straight to the
                    // permission prompt UI so the user decides.
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
                        description: "[Oracle escalated] \(p.toolCall?.title ?? "Grok is requesting permission.")",
                        options: options
                    )))
                    return
                }
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
            // Autonomous policy: answer ourselves (no human) when this Node's
            // auto-approval level covers the tool's action kind — so a delegated,
            // unattended Node doesn't stall on every prompt.
            if autoApproval.autoApproves(kind: p.toolCall?.kind),
               let allow = p.options.first(where: { $0.kind == "allow_once" })
                        ?? p.options.first(where: { $0.kind == "allow_always" }) {
                respond(id: id, result: selectedOutcome(allow.optionId))
                emit(.activity(ActivityEvent(
                    sessionId: p.sessionId ?? sessionId ?? "",
                    note: "Auto-approved (\(autoApproval.level.rawValue): \(p.toolCall?.kind ?? "tool")): \(p.toolCall?.title ?? "permission")",
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

extension GrokBuildSessionClient {
    /// Extracts an image artifact path from a `tool_call_update` line's `rawOutput`
    /// (grok's image tools report `{ type, path, filename }` there). Decoded
    /// *independently* of the main `Update` decode so an unrelated tool's differently
    /// shaped `rawOutput` can never break the primary path. Returns the path only when
    /// it points at a renderable image file.
    static func imageResultPath(in line: Data) -> String? {
        struct Wire: Decodable {
            struct Params: Decodable {
                struct Update: Decodable {
                    struct RawOutput: Decodable { let type: String?; let path: String? }
                    let rawOutput: RawOutput?
                }
                let update: Update
            }
            let params: Params
        }
        guard let path = (try? JSONDecoder().decode(Wire.self, from: line))?.params.update.rawOutput?.path,
              !path.isEmpty else { return nil }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
        guard imageExts.contains((path as NSString).pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
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
    // Standard ACP top-level fields (grok leaves these empty and uses `_meta`;
    // adapters like Claude Code populate them). `authMethods` lets us surface a
    // clear "needs login" message instead of a silent session/new failure.
    let agentInfo: AgentInfo?
    let authMethods: [AuthMethod]?
    enum CodingKeys: String, CodingKey { case meta = "_meta", agentInfo, authMethods }

    struct AgentInfo: Decodable { let name: String?; let title: String?; let version: String? }
    struct AuthMethod: Decodable { let id: String?; let name: String?; let description: String? }

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
