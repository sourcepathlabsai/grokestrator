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
    /// dynamically routed per task. Default `.grok` — the existing grok
    /// path via `command`/`arguments`, so nothing regresses. See
    /// `design/12-model-agnostic-runtime.md`.
    public var brain: BrainBinding

    /// What this Node's brain is allowed to *do* — the app-owned capability layer
    /// (design/11 guardrails, design/12 Phase C). Enforced for model-agnostic
    /// backends (where the app runs the tool loop); grok manages its own tools.
    /// Default `.unrestricted`, so nothing regresses.
    public var toolPolicy: ToolPolicy

    /// Which host MCP servers (`MCPRegistry`) this Node may reach. `nil` ⇒ all
    /// (unrestricted, like `ToolPolicy.allowed`); `[]` ⇒ none; `[ids]` ⇒ a subset.
    /// grok Nodes get the granted set injected into `session/new`; API-brain Nodes
    /// reach them via the in-app MCP client. Default `nil` keeps parity.
    public var grantedMCPServerIDs: [UUID]?

    /// How much of this Node's ACP tool-permission prompts the app auto-answers (so a
    /// delegated/unattended Node doesn't stall on every call). Default `.manual` —
    /// ask for everything, as before. Only meaningful for ACP nodes (grok/Claude).
    public var autoApproval: AutoApproval

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
        brain: BrainBinding = .grok,
        toolPolicy: ToolPolicy = .unrestricted,
        grantedMCPServerIDs: [UUID]? = nil,
        autoApproval: AutoApproval = .manual,
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
        self.toolPolicy = toolPolicy
        self.grantedMCPServerIDs = grantedMCPServerIDs
        self.autoApproval = autoApproval
        self.status = status
        self.lastStartedAt = lastStartedAt
        self.lastExitCode = lastExitCode
        self.pid = pid
    }

    // Forward-compatible decoding so older saved JSON (without `shared`/`archived`)
    // still loads — `init(from:)` defaults the new fields.
    enum CodingKeys: String, CodingKey {
        case id, name, command, arguments, workingDirectory, environmentOverrides,
             autoRestart, shared, archived, role, parentID, rolePrompt, brain, toolPolicy,
             grantedMCPServerIDs, autoApproval, status, lastStartedAt, lastExitCode, pid
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
        self.brain = try c.decodeIfPresent(BrainBinding.self, forKey: .brain) ?? .grok
        self.toolPolicy = try c.decodeIfPresent(ToolPolicy.self, forKey: .toolPolicy) ?? .unrestricted
        self.grantedMCPServerIDs = try c.decodeIfPresent([UUID].self, forKey: .grantedMCPServerIDs)
        self.autoApproval = try c.decodeIfPresent(AutoApproval.self, forKey: .autoApproval) ?? .manual
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

    // Stable, human-editable Codable (discriminated by `kind`) — config is
    // hand-/UI-editable in connections.json, not an opaque synthesized shape.
    private enum CodingKeys: String, CodingKey { case kind, baseURL, model, apiKeyRef, modelPath }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .grokACP:
            try c.encode("grokACP", forKey: .kind)
        case .openAICompatible(let baseURL, let model, let apiKeyRef):
            try c.encode("openAICompatible", forKey: .kind)
            try c.encode(baseURL, forKey: .baseURL); try c.encode(model, forKey: .model)
            try c.encodeIfPresent(apiKeyRef, forKey: .apiKeyRef)
        case .gemini(let model, let apiKeyRef):
            try c.encode("gemini", forKey: .kind)
            try c.encode(model, forKey: .model); try c.encodeIfPresent(apiKeyRef, forKey: .apiKeyRef)
        case .onboard(let modelPath):
            try c.encode("onboard", forKey: .kind); try c.encode(modelPath, forKey: .modelPath)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "grokACP" {
        case "openAICompatible":
            self = .openAICompatible(baseURL: try c.decode(String.self, forKey: .baseURL),
                                     model: try c.decode(String.self, forKey: .model),
                                     apiKeyRef: try c.decodeIfPresent(String.self, forKey: .apiKeyRef))
        case "gemini":
            self = .gemini(model: try c.decode(String.self, forKey: .model),
                           apiKeyRef: try c.decodeIfPresent(String.self, forKey: .apiKeyRef))
        case "onboard":
            self = .onboard(modelPath: try c.decode(String.self, forKey: .modelPath))
        default:
            self = .grokACP
        }
    }
}

/// An abstract capability tier the orchestrator reasons in (not a model string). A
/// host-level tier map resolves each to a concrete `AgentBackend`.
public enum Tier: String, Codable, Hashable, Sendable, CaseIterable {
    case fast, balanced, deep
}

/// A named, reusable "brain" in the host-local catalog — a concrete `AgentBackend`
/// (provider + model + key *name*) the user has curated and can point Nodes/tiers
/// at. Multiple profiles per service are the point: "Cerebras · GPT-OSS 120B" and
/// "Cerebras · Llama-4 Scout" are two profiles, so a Node/tier can pick the model
/// most appropriate for its task. No secrets here — only an `apiKeyRef` name (the
/// value lives in `.env.local_llm`). See `design/12-model-agnostic-runtime.md`.
public struct BrainProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var backend: AgentBackend
    public init(id: UUID = UUID(), name: String, backend: AgentBackend) {
        self.id = id; self.name = name; self.backend = backend
    }
}

/// The host-local library of `BrainProfile`s (gitignored `brains.json`). Curated by
/// the user; referenced by id from Nodes (`BrainBinding.profile`) and the tier map
/// (`BrainRef.profile`). A reference to a missing profile resolves to grok.
public struct BrainCatalog: Codable, Hashable, Sendable {
    public var profiles: [BrainProfile]
    public init(profiles: [BrainProfile] = []) { self.profiles = profiles }

    public func profile(_ id: UUID) -> BrainProfile? { profiles.first { $0.id == id } }

    /// The backend for a profile id — grok if the id is dangling (profile deleted).
    public func backend(for id: UUID) -> AgentBackend { profile(id)?.backend ?? .grokACP }

    /// Find an existing profile whose backend matches, else append a new one with
    /// `name`, returning its id. Used by migration to absorb legacy inline backends.
    public mutating func findOrCreate(backend: AgentBackend, name: @autoclosure () -> String) -> UUID {
        if let existing = profiles.first(where: { $0.backend == backend }) { return existing.id }
        let profile = BrainProfile(name: name(), backend: backend)
        profiles.append(profile)
        return profile.id
    }
}

/// A reference to a brain: grok (the Node's own command) or a catalog profile by id.
/// Used by the tier map so a tier can resolve to either. Lenient decode: anything
/// that isn't an explicit `profile` resolves to grok (legacy/forward-compatible).
public enum BrainRef: Codable, Hashable, Sendable {
    case grok
    case profile(UUID)

    private enum CodingKeys: String, CodingKey { case kind, id }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .grok: try c.encode("grok", forKey: .kind)
        case .profile(let id): try c.encode("profile", forKey: .kind); try c.encode(id, forKey: .id)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(String.self, forKey: .kind) == "profile",
           let id = try c.decodeIfPresent(UUID.self, forKey: .id) {
            self = .profile(id)
        } else {
            self = .grok
        }
    }
}

/// Host-local resolution of each abstract `Tier` to a `BrainRef`. Lives on the host
/// (gitignored `tiermap.json`) — machine config, not per-Node and not synced. A
/// `dynamic` `BrainBinding` resolves its tier through this map; per-task tier
/// *selection/escalation* lands in Phase D. Unmapped tiers fall back to grok.
public struct HostTierMap: Codable, Hashable, Sendable {
    /// Brain reference per tier. A missing entry ⇒ grok (the safe default).
    public var entries: [Tier: BrainRef]

    public init(entries: [Tier: BrainRef] = [:]) { self.entries = entries }

    /// Every tier mapped to grok — the behavior-preserving default.
    public static let `default` = HostTierMap(
        entries: [.fast: .grok, .balanced: .grok, .deep: .grok]
    )

    // Encode as `{ "fast": {…}, "balanced": {…} }` keyed by tier rawValue so
    // `tiermap.json` stays hand-editable (Swift would otherwise emit a positional
    // array for a non-String-keyed dictionary).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TierKey.self)
        var out: [Tier: BrainRef] = [:]
        for tier in Tier.allCases {
            if let ref = try c.decodeIfPresent(BrainRef.self, forKey: TierKey(tier)) {
                out[tier] = ref
            }
        }
        self.entries = out
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TierKey.self)
        for (tier, ref) in entries { try c.encode(ref, forKey: TierKey(tier)) }
    }
    private struct TierKey: CodingKey {
        let stringValue: String
        init(_ tier: Tier) { self.stringValue = tier.rawValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public func ref(for tier: Tier) -> BrainRef { entries[tier] ?? .grok }

    /// The concrete backend for a brain reference, resolved through the catalog.
    public func backend(for ref: BrainRef, catalog: BrainCatalog) -> AgentBackend {
        switch ref {
        case .grok:             return .grokACP
        case .profile(let id):  return catalog.backend(for: id)
        }
    }

    /// Resolve a binding to the backend to run *now*: grok → grok; a profile binding
    /// → its catalog backend; a dynamic binding → its **default tier**'s ref through
    /// the map. (Per-task routing across `allowed` is Phase D.) `inlineLegacy` is a
    /// pre-migration safety net — it returns the embedded backend directly.
    public func backend(for binding: BrainBinding, catalog: BrainCatalog) -> AgentBackend {
        switch binding {
        case .grok:                        return .grokACP
        case .profile(let id):             return catalog.backend(for: id)
        case .dynamic(let defaultTier, _): return backend(for: ref(for: defaultTier), catalog: catalog)
        case .inlineLegacy(let backend):   return backend
        }
    }
}

/// What a Node's brain may *do* — the app-owned capability layer (design/11
/// guardrails, design/12 Phase C). `capability` bounds the kind of action;
/// `allowed` optionally narrows to specific tool names within that bound.
public struct ToolPolicy: Codable, Hashable, Sendable {
    public enum Capability: String, Codable, Hashable, Sendable {
        case readOnly      // read/list only
        case readWrite     // + write files
        case execute       // + run commands
    }
    public var capability: Capability
    /// Tool-name allowlist within the capability; `nil` = all tools the capability permits.
    public var allowed: [String]?

    public init(capability: Capability = .execute, allowed: [String]? = nil) {
        self.capability = capability
        self.allowed = allowed
    }
    /// The default: full capability, no allowlist — preserves prior behavior.
    public static let unrestricted = ToolPolicy()
}

/// How much of an **ACP agent's** (grok / Claude Code) tool-permission prompts the
/// app answers *without* a human — so a Node delegated an unattended task doesn't
/// stall on every call. Graded by the ACP tool-call `kind`, mirroring the capability
/// tiers. `manual` (default) preserves "ask for everything." Only applies to ACP
/// nodes; API brains already auto-execute within `ToolPolicy`. See design/11/12.
public struct AutoApproval: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Hashable, Sendable, CaseIterable {
        case manual   // ask for everything (default — supervised)
        case reads    // auto-approve read-only actions (read/search/fetch/think); ask the rest
        case edits    // + file edits/moves; ask for execute/delete
        case all      // auto-approve everything (fully autonomous — trust the agent)
    }
    public var level: Level
    public init(level: Level = .manual) { self.level = level }
    public static let manual = AutoApproval()

    /// Whether a permission with this ACP tool `kind` should be auto-approved.
    public func autoApproves(kind: String?) -> Bool {
        switch level {
        case .manual: return false
        case .all:    return true
        case .reads:  return Self.isRead(kind)
        case .edits:  return Self.isRead(kind) || Self.isEdit(kind)
        }
    }
    private static func isRead(_ kind: String?) -> Bool {
        switch kind { case "read", "search", "fetch", "think": return true; default: return false }
    }
    private static func isEdit(_ kind: String?) -> Bool {
        // `delete` and `execute` are destructive/powerful — they need `.all`.
        switch kind { case "edit", "move": return true; default: return false }
    }
}

/// How a Node's brain is chosen: `grok` (its own command), a catalog `profile` by
/// id, or `dynamic` (the orchestrator routes each task to a tier, resolved + clamped
/// to `allowed`). `inlineLegacy` is produced only when decoding a pre-catalog config
/// that pinned an inline API backend — the model migrates it into a catalog profile
/// at load (`migrateBrainsIfNeeded`); it is never encoded.
public enum BrainBinding: Codable, Hashable, Sendable {
    case grok
    case profile(UUID)
    case dynamic(defaultTier: Tier, allowed: [Tier])
    case inlineLegacy(AgentBackend)

    /// The catalog profile this binding references, if any.
    public var profileID: UUID? { if case .profile(let id) = self { return id }; return nil }

    private enum CodingKeys: String, CodingKey { case mode, id, backend, defaultTier, allowed }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .grok:
            try c.encode("grok", forKey: .mode)
        case .profile(let id):
            try c.encode("profile", forKey: .mode); try c.encode(id, forKey: .id)
        case .dynamic(let defaultTier, let allowed):
            try c.encode("dynamic", forKey: .mode)
            try c.encode(defaultTier, forKey: .defaultTier); try c.encode(allowed, forKey: .allowed)
        case .inlineLegacy(let backend):
            // Should be migrated before any save; encode as grok as a safety net so a
            // stray inline binding can never break resolution.
            _ = backend
            try c.encode("grok", forKey: .mode)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .mode) ?? "grok" {
        case "profile":
            self = .profile(try c.decode(UUID.self, forKey: .id))
        case "dynamic":
            self = .dynamic(defaultTier: try c.decode(Tier.self, forKey: .defaultTier),
                            allowed: try c.decode([Tier].self, forKey: .allowed))
        case "pinned":
            // Legacy: `.pinned(AgentBackend)`. grok stays grok; an inline API backend
            // becomes `.inlineLegacy` for the load-time migration to absorb.
            let backend = (try? c.decode(AgentBackend.self, forKey: .backend)) ?? .grokACP
            self = (backend == .grokACP) ? .grok : .inlineLegacy(backend)
        default:
            self = .grok
        }
    }
}

public enum InstanceStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case stopped
    case starting
    case running
    case stopping
    case crashed
    case errored
}
