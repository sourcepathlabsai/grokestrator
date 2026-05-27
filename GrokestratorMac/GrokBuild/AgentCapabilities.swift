import Foundation

/// A snapshot of what a Grok Build instance can do, captured from the ACP
/// `initialize` result and kept current by `available_commands_update`.
///
/// This is the data the Instance Inspector (design/02 right panel) renders and
/// the source for the composer's slash-command popup. It is deliberately
/// **secret-free**: MCP server `env` values (which the `initialize` payload
/// carries in plaintext — Obsidian/neo4j/postgres credentials) are never copied
/// in here. We keep only the server's identity and transport.
public struct AgentCapabilities: Sendable, Equatable {
    public var agentVersion: String?
    public var workingDirectory: String?
    public var currentModelId: String?
    public var models: [AgentModel]
    public var mcpServers: [MCPServerInfo]
    public var commands: [SlashCommand]

    public init(
        agentVersion: String? = nil,
        workingDirectory: String? = nil,
        currentModelId: String? = nil,
        models: [AgentModel] = [],
        mcpServers: [MCPServerInfo] = [],
        commands: [SlashCommand] = []
    ) {
        self.agentVersion = agentVersion
        self.workingDirectory = workingDirectory
        self.currentModelId = currentModelId
        self.models = models
        self.mcpServers = mcpServers
        self.commands = commands
    }

    public static let empty = AgentCapabilities()

    /// The active model (by `currentModelId`), falling back to the first listed.
    public var currentModel: AgentModel? {
        models.first { $0.id == currentModelId } ?? models.first
    }
}

/// One model the instance can run. `id` is the ACP `modelId`.
public struct AgentModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let description: String?
    public let contextTokens: Int?

    public init(id: String, name: String?, description: String?, contextTokens: Int?) {
        self.id = id
        self.name = name
        self.description = description
        self.contextTokens = contextTokens
    }
}

/// An MCP server configured on the instance. Identity + transport only — no
/// `env`/secret material is ever carried here.
public struct MCPServerInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let type: String?      // "stdio" | "http" | "sse"
    public let command: String?   // e.g. "npx", "uvx" (the launcher, not its secret args)

    public init(id: String, name: String?, type: String?, command: String?) {
        self.id = id
        self.name = name
        self.type = type
        self.command = command
    }

    /// A human label: the configured name, else the launching command.
    public var displayName: String { name ?? command ?? "server" }
}

/// A slash command the instance advertises (built-ins like `/compact` and
/// skills like `/graphify`). `hint` is the argument hint, when the command takes one.
public struct SlashCommand: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let hint: String?

    public init(name: String, description: String?, hint: String?) {
        self.name = name
        self.description = description
        self.hint = hint
    }
}
