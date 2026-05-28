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
        self.status = status
        self.lastStartedAt = lastStartedAt
        self.lastExitCode = lastExitCode
        self.pid = pid
    }

    // Forward-compatible decoding so older saved JSON (without `shared`/`archived`)
    // still loads — `init(from:)` defaults the new fields.
    enum CodingKeys: String, CodingKey {
        case id, name, command, arguments, workingDirectory, environmentOverrides,
             autoRestart, shared, archived,
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
        self.status = try c.decodeIfPresent(InstanceStatus.self, forKey: .status) ?? .stopped
        self.lastStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastStartedAt)
        self.lastExitCode = try c.decodeIfPresent(Int32.self, forKey: .lastExitCode)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
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
