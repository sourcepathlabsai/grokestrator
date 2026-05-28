import Foundation
import GrokestratorCore

/// Single seam between the UI and the actual conversation source — local
/// in-process (`LiveConversationDriver`), offline scripted (`MockConversationDriver`),
/// or over the wire to a remote GKSS (`RemoteConversationDriver`).
///
/// **Broadcast model (PR B):** the driver no longer hands the caller a per-call
/// stream of updates. Instead, the caller `subscribe()`s once and receives every
/// update for the Connection — including snapshots on join and updates
/// initiated from *other* clients. `send` is fire-and-forget.
public protocol ConversationDriver: Sendable {
    /// Fire a prompt at the underlying source. Updates flow out via `subscribe()`
    /// (which must be running on this driver), not back through this call.
    func send(_ prompt: String) async throws

    /// Open the Connection's broadcast stream. First event is `.snapshot` with
    /// the current transcript; subsequent events are `.update`s indefinitely,
    /// covering updates initiated from any client.
    func subscribe() async -> AsyncStream<ConnectionStreamEvent>

    /// Answer a pending permission request with the chosen ACP `optionId`.
    func respondToPermission(permissionId: String, optionId: String) async

    /// The instance's capabilities (model, MCP servers, slash commands).
    func capabilities() async -> AgentCapabilities?

    /// Token / context usage for the session (inspector).
    func usage() async -> SessionUsage?
}

/// Drives a conversation against the local Mac's own `GrokBuildManager` —
/// the in-process equivalent of `RemoteConversationDriver`. Both subscribe to
/// the same broadcast plumbing, so the local UI sees turns initiated from
/// remote clients identically to its own.
public struct LiveConversationDriver: ConversationDriver {
    public let manager: GrokBuildManager
    public let instanceID: UUID

    public init(manager: GrokBuildManager, instanceID: UUID) {
        self.manager = manager
        self.instanceID = instanceID
    }

    public func send(_ prompt: String) async throws {
        _ = try await manager.sendPrompt(to: instanceID, prompt: prompt)
    }

    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        // If the conversation can't be created (e.g. process not yet launched),
        // return an empty terminated stream — the UI will show no history.
        (try? await manager.subscribe(to: instanceID)) ?? AsyncStream { $0.finish() }
    }

    public func respondToPermission(permissionId: String, optionId: String) async {
        try? await manager.respondToPermission(for: instanceID, permissionId: permissionId, chosenOption: optionId)
    }

    public func capabilities() async -> AgentCapabilities? {
        try? await manager.capabilities(for: instanceID)
    }

    public func usage() async -> SessionUsage? {
        await manager.usage(for: instanceID)
    }
}

/// Scripted, delayed updates that resemble a real turn (thoughts, notes, a
/// tool call, a permission it waits on, then a final message). Powers the
/// "Mock Grok (offline)" connection so the UI is demoable without grok.
public actor MockConversationDriver: ConversationDriver {
    public let label: String
    /// Mock-side broadcaster — every `send` fans updates into here so a `subscribe()`
    /// running in the UI sees them. The first event yielded after subscribe is
    /// a `.snapshot([])` since the mock keeps no persistent history.
    private var subscribers: [UUID: AsyncStream<ConnectionStreamEvent>.Continuation] = [:]
    private var permissionContinuation: CheckedContinuation<String, Never>?

    public init(label: String = "mock") {
        self.label = label
    }

    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        let (stream, cont) = AsyncStream<ConnectionStreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        subscribers[token] = cont
        cont.yield(.snapshot([]))
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        return stream
    }

    private func removeSubscriber(_ token: UUID) { subscribers.removeValue(forKey: token) }

    private func broadcast(_ update: ConversationUpdate) {
        for (_, c) in subscribers { c.yield(.update(update)) }
    }

    public func send(_ prompt: String) async throws {
        // Kick off the scripted turn detached so this call returns immediately
        // (fire-and-forget per the broadcast contract).
        Task { await self.runScriptedTurn(for: prompt) }
    }

    private func runScriptedTurn(for prompt: String) async {
        func emit(_ update: ConversationUpdate, after ms: UInt64 = 450) async {
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            broadcast(update)
        }

        let thought = "Parsing request: \"\(prompt)\""
        for word in thought.split(separator: " ") {
            await emit(.thoughtDelta(String(word) + " "), after: 60)
        }
        await emit(.thought(thought, metadata: nil), after: 100)

        await emit(.progressNote("Scanning workspace", phase: "scan", metadata: nil))
        await emit(.toolCallRequested(ToolCallInfo(id: "t1", toolName: "run_shell", arguments: ["command": "rm -rf build/"], sessionId: nil)))

        await emit(.permissionRequested(PermissionRequestInfo(
            id: "mock-perm-1",
            description: "Run shell command: rm -rf build/",
            options: [
                PermissionOption(id: "always-allow", label: "Yes, and don't ask again", kind: "allow_always"),
                PermissionOption(id: "allow-once", label: "Yes, proceed", kind: "allow_once"),
                PermissionOption(id: "reject-once", label: "No, tell Grok what to do differently", kind: "reject_once"),
            ],
            sessionId: nil
        )), after: 200)

        let choice = await awaitPermission()
        let approved = choice.hasPrefix("allow") || choice.hasPrefix("always")
        await emit(.activityNote("Permission: \(approved ? "approved" : "rejected") (\(choice))", kind: "permission", metadata: nil), after: 50)

        let answer = approved
            ? "(\(label)) Done — removed build/. Here's a chime: /System/Library/Sounds/Glass.aiff"
            : "(\(label)) OK, I won't run that. What would you like instead?"
        for word in answer.split(separator: " ") {
            await emit(.messageDelta(String(word) + " "), after: 70)
        }
        await emit(.message(answer, metadata: nil), after: 120)
        await emit(.turnComplete(finalAnswer: answer), after: 150)
    }

    public func respondToPermission(permissionId _: String, optionId: String) async {
        permissionContinuation?.resume(returning: optionId)
        permissionContinuation = nil
    }

    /// A representative canned capability set so the inspector / slash popup
    /// are demoable without a live grok.
    public func capabilities() async -> AgentCapabilities? {
        AgentCapabilities(
            agentVersion: "0.2.3 (mock)",
            workingDirectory: FileManager.default.currentDirectoryPath,
            currentModelId: "grok-build",
            models: [AgentModel(id: "grok-build", name: "Grok Build", description: "Best for advanced coding tasks", contextTokens: 512_000)],
            mcpServers: [
                MCPServerInfo(id: "context7", name: "context7", type: "stdio", command: "npx"),
                MCPServerInfo(id: "obsidian", name: "obsidian", type: "stdio", command: "npx"),
            ],
            commands: GrokBuiltinCommands.merged(advertised: [
                SlashCommand(name: "graphify", description: "Turn any input into a knowledge graph", hint: nil),
                SlashCommand(name: "help", description: "Grok docs — config, MCP, auth, skills, commands", hint: nil),
            ])
        )
    }

    public func usage() async -> SessionUsage? {
        SessionUsage(totalTokens: 16435, contextWindow: 512_000, inputTokens: 16323,
                     outputTokens: 112, cachedReadTokens: 14080, reasoningTokens: 111)
    }

    private func awaitPermission() async -> String {
        await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
        }
    }
}
