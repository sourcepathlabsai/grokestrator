import Foundation

/// User-facing name for `ManagedInstance` — the persistent Connection primitive
/// the user creates with the "+" button. The underlying type is being renamed
/// gradually; new code uses `ManagedConnection`, old call sites continue to
/// compile via this alias. See `memory/gradual-rename-instance-to-connection`.
public typealias ManagedConnection = ManagedInstance

/// Configuration and runtime description of a Grok Build connection that the
/// Grokestrator server is responsible for managing (launch, restart, monitor).
/// Lives primarily on the server (Mac hybrid app) but is shared via the protocol
/// so clients can see status and target specific connections.
public struct ManagedInstance: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // Friendly name, e.g. "main", "research", "agent-2"
    public var command: String              // Full path or command, e.g. "/opt/homebrew/bin/grok" or "grok"
    public var arguments: [String]          // e.g. ["agent", "stdio"] or specific flags
    public var workingDirectory: String?
    public var environmentOverrides: [String: String]?

    /// Auto-launch on GKSS boot (and currently the hook for crash-restart, future).
    public var autoRestart: Bool

    /// Whether remote GKSC clients see this Connection. `false` ⇒ local-only.
    /// Default true: Tailscale is the trust boundary (see `connection-semantics`).
    public var shared: Bool

    /// Soft-deleted: hidden from the main sidebar and from every remote client,
    /// `autoRestart` is ignored on boot. Restorable via the Archived view.
    /// Permanently deleting an archived Connection drops config + history.
    public var archived: Bool

    /// This Connection's place in the orchestration tree: an `agent` (leaf — does
    /// work) or an `orchestrator` (coordinates children). See
    /// `design/11-orchestration-platform.md`. Default `.agent` so existing
    /// Connections and older saved JSON keep behaving exactly as before.
    public var role: NodeRole

    /// Soft parent edge in the orchestration tree: the `id` of the orchestrator
    /// Connection this one reports to, or `nil` for a root. This is *only* an edge
    /// between sibling Connections — the "1 Connection = 1 grok instance, no nested
    /// chats" rule (see `connection-semantics`) still holds; nothing is nested.
    public var parentID: UUID?

    /// The Node's role/system prompt — what makes it behave as Observe / Orient /
    /// Decide / Act, etc. grok's `agent stdio` ignores `--system-prompt-override`
    /// and friends (verified), so this is injected into the prompt stream as a
    /// one-time preamble on the session's first turn. `nil`/empty ⇒ no role prompt.
    /// See `design/11-orchestration-platform.md` and `grok-stdio-system-prompt`.
    public var rolePrompt: String?

    /// Which LLM ("brain") runs this Node, and whether it's hard-wired or
    /// dynamically routed per task. Default `.pinned(.grokACP)` — the existing grok
    /// path via `command`/`arguments`, so nothing regresses. See
    /// `design/12-model-agnostic-runtime.md`. (Phase A: config only; the runtime
    /// still always launches grok until later phases add other backends.)
    public var brain: BrainBinding

    // Runtime (not persisted the same way)
    public var status: InstanceStatus
    public var lastStartedAt: Date?
    public var lastExitCode: Int32?
    public var pid: Int32?

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environmentOverrides: [String: String]? = nil,
        autoRestart: Bool = true,
        shared: Bool = true,
        archived: Bool = false,
        role: NodeRole = .agent,
        parentID: UUID? = nil,
        rolePrompt: String? = nil,
        brain: BrainBinding = .pinned(.grokACP),
        status: InstanceStatus = .stopped,
        lastStartedAt: Date? = nil,
        lastExitCode: Int32? = nil,
        pid: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.autoRestart = autoRestart
        self.shared = shared
        self.archived = archived
        self.role = role
        self.parentID = parentID
        self.rolePrompt = rolePrompt
        self.brain = brain
        self.status = status
        self.lastStartedAt = lastStartedAt
        self.lastExitCode = lastExitCode
        self.pid = pid
    }

    // Forward-compatible decoding so older saved JSON (without `shared`/`archived`)
    // still loads — `init(from:)` defaults the new fields.
    enum CodingKeys: String, CodingKey {
        case id, name, command, arguments, workingDirectory, environmentOverrides,
             autoRestart, shared, archived, role, parentID, rolePrompt, brain,
             status, lastStartedAt, lastExitCode, pid
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.command = try c.decode(String.self, forKey: .command)
        self.arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.environmentOverrides = try c.decodeIfPresent([String: String].self, forKey: .environmentOverrides)
        self.autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
        self.shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? true
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.role = try c.decodeIfPresent(NodeRole.self, forKey: .role) ?? .agent
        self.parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        self.rolePrompt = try c.decodeIfPresent(String.self, forKey: .rolePrompt)
        self.brain = try c.decodeIfPresent(BrainBinding.self, forKey: .brain) ?? .pinned(.grokACP)
        self.status = try c.decodeIfPresent(InstanceStatus.self, forKey: .status) ?? .stopped
        self.lastStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastStartedAt)
        self.lastExitCode = try c.decodeIfPresent(Int32.self, forKey: .lastExitCode)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
    }
}

/// A Connection's role in the orchestration tree. `agent` is the default and the
/// only behavior today; `orchestrator` marks a Connection that coordinates child
/// Connections (the `parentID` edge points up at one). See
/// `design/11-orchestration-platform.md`.
public enum NodeRole: String, Codable, Hashable, Sendable, CaseIterable {
    case agent
    case orchestrator
}

/// Which LLM runtime ("brain") backs a Node. `grokACP` (the default) launches grok
/// via the Connection's own `command`/`arguments`; the others are declared now and
/// implemented in later phases. See `design/12-model-agnostic-runtime.md`.
public enum AgentBackend: Codable, Hashable, Sendable {
    case grokACP                                                    // uses command/arguments
    case openAICompatible(baseURL: String, model: String, apiKeyRef: String?)
    case gemini(model: String, apiKeyRef: String?)
    case onboard(modelPath: String)
}

/// An abstract capability tier the orchestrator reasons in (not a model string). A
/// host-level tier map resolves each to a concrete `AgentBackend`.
public enum Tier: String, Codable, Hashable, Sendable, CaseIterable {
    case fast, balanced, deep
}

/// How a Node's brain is chosen. `pinned` hard-wires one backend; `dynamic` lets the
/// orchestrator route each task to a tier (resolved + clamped to `allowed`).
public enum BrainBinding: Codable, Hashable, Sendable {
    case pinned(AgentBackend)
    case dynamic(defaultTier: Tier, allowed: [Tier])
}

public enum InstanceStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case stopped
    case starting
    case running
    case stopping
    case crashed
    case errored
}
