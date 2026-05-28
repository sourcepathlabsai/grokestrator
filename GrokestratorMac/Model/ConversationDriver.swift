import Foundation
import GrokestratorCore

/// Abstraction over "send a prompt, get a stream of updates".
///
/// This is the single seam between the UI and whatever is actually driving a
/// conversation. Today the UI runs against `MockConversationDriver` so we can
/// iterate on the experience without a live `grok` process; `LiveConversationDriver`
/// wires the exact same surface to the real Grok Build black box (`GrokBuildManager`).
public protocol ConversationDriver: Sendable {
    /// Sends a prompt and returns a stream of high-level conversation updates.
    func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate>

    /// Answers a pending permission request with the chosen ACP `optionId`.
    func respondToPermission(permissionId: String, optionId: String) async

    /// The instance's capabilities (model, MCP servers, slash commands) for the
    /// Instance Inspector and slash-command popup. `nil` if unavailable.
    func capabilities() async -> AgentCapabilities?

    /// Token / context usage for the session (inspector). `nil` if unavailable.
    func usage() async -> SessionUsage?
}

/// Drives a conversation against a real Grok Build instance via the black box.
///
/// Not used by the default (mock) app state yet — it exists so the wiring point
/// is explicit and compiles. The next slice will launch real instances and hand
/// these to the app model.
public struct LiveConversationDriver: ConversationDriver {
    public let manager: GrokBuildManager
    public let instanceID: UUID

    public init(manager: GrokBuildManager, instanceID: UUID) {
        self.manager = manager
        self.instanceID = instanceID
    }

    public func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        try await manager.sendPrompt(to: instanceID, prompt: prompt)
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

/// Produces a scripted, delayed stream of updates that resembles a real turn
/// (thoughts, notes, a tool call, a **permission request it waits on**, then a
/// final message). Lets us build and feel the UI — including the permission
/// overlay — before wiring real processes.
public actor MockConversationDriver: ConversationDriver {
    public let label: String
    private var permissionContinuation: CheckedContinuation<String, Never>?

    public init(label: String = "mock") {
        self.label = label
    }

    public func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        AsyncStream { continuation in
            let task = Task {
                func emit(_ update: ConversationUpdate, after ms: UInt64 = 450) async {
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                    guard !Task.isCancelled else { return }
                    continuation.yield(update)
                }

                let thought = "Parsing request: \"\(prompt)\""
                for word in thought.split(separator: " ") {
                    await emit(.thoughtDelta(String(word) + " "), after: 60)
                }
                await emit(.thought(thought, metadata: nil), after: 100)

                await emit(.progressNote("Scanning workspace", phase: "scan", metadata: nil))
                await emit(.toolCallRequested(ToolCallInfo(id: "t1", toolName: "run_shell", arguments: ["command": "rm -rf build/"], sessionId: nil)))

                // Ask the user for permission and wait for their choice.
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

                let choice = await self.awaitPermission()
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
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respondToPermission(permissionId _: String, optionId: String) async {
        permissionContinuation?.resume(returning: optionId)
        permissionContinuation = nil
    }

    /// A representative canned capability set (mirrors real grok 0.2.3) so the
    /// inspector and slash-command popup are demoable without a live process.
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
            // Built-in catalog ∪ a couple of representative advertised skills.
            commands: GrokBuiltinCommands.merged(advertised: [
                SlashCommand(name: "graphify", description: "Turn any input into a knowledge graph", hint: nil),
                SlashCommand(name: "help", description: "Grok docs — config, MCP, auth, skills, commands", hint: nil),
            ])
        )
    }

    /// A canned usage snapshot (mirrors a real grok turn) for offline demoing.
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
