import Foundation

/// Configuration and runtime description of a Grok Build instance that the
/// Grokestrator server is responsible for managing (launch, restart, monitor).
/// Lives primarily on the server (Mac hybrid app) but is shared via the protocol
/// so clients can see status and target specific instances.
public struct ManagedInstance: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // Friendly name, e.g. "main", "research", "agent-2"
    public var command: String              // Full path or command, e.g. "/opt/homebrew/bin/grok" or "grok"
    public var arguments: [String]          // e.g. ["agent", "serve", "--stdio"] or specific flags
    public var workingDirectory: String?
    public var environmentOverrides: [String: String]?

    /// If true, the server will automatically restart this instance on crash or on app launch.
    public var autoRestart: Bool

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
        self.status = status
        self.lastStartedAt = lastStartedAt
        self.lastExitCode = lastExitCode
        self.pid = pid
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
