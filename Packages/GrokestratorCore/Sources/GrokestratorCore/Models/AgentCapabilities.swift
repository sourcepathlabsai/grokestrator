import Foundation

/// A snapshot of what a Grok Build instance can do, captured from the ACP
/// `initialize` result and kept current by `available_commands_update`.
///
/// Lives in Core because it crosses the wire: a remote Grokestrator client (the
/// Mac client driving another Mac's server, or an iOS client) needs the same
/// shape to populate its Instance Inspector.
///
/// Deliberately **secret-free**: MCP server `env` values (which grok's
/// `initialize` payload carries in plaintext — Obsidian/neo4j/postgres
/// credentials) are never copied in here. Only identity and transport.
public struct AgentCapabilities: Sendable, Equatable, Codable {
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
public struct AgentModel: Sendable, Equatable, Codable, Identifiable {
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
public struct MCPServerInfo: Sendable, Equatable, Codable, Identifiable {
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
public struct SlashCommand: Sendable, Equatable, Codable, Identifiable {
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

/// Curated catalog of grok's documented built-in slash commands (see
/// `~/.grok/docs/user-guide/04-slash-commands.md`, mirrored in design/09).
///
/// Grok exposes commands from two sources: *shell builtins* (advertised over ACP
/// in `availableCommands` — we capture those live) and *pager builtins* handled
/// by grok's own TUI, which Grokestrator replaces, so they never reach us over
/// the wire. This catalog backfills the documented commands that make sense when
/// driving the agent over ACP. Pure terminal-UI toggles (`/exit`, `/home`,
/// `/theme`, `/vim-mode`, `/multiline`, `/compact-mode`, `/terminal-setup`,
/// `/release-notes`) are intentionally omitted — they control a TUI we don't use.
public enum GrokBuiltinCommands {
    public static let catalog: [SlashCommand] = [
        .init(name: "new", description: "Start a new session, clearing the conversation", hint: nil),
        .init(name: "load", description: "Load a previous session from disk", hint: "[session-id]"),
        .init(name: "compact", description: "Compress conversation history to save context", hint: "[context]"),
        .init(name: "context", description: "Show context window usage and session stats", hint: nil),
        .init(name: "session-info", description: "Show session details (model, turns, context)", hint: nil),
        .init(name: "share", description: "Share the session and print the URL", hint: nil),
        .init(name: "rename", description: "Rename the current session", hint: "<title>"),
        .init(name: "model", description: "Switch to a different model", hint: "<name>"),
        .init(name: "always-approve", description: "Toggle always-approve (skip permission prompts)", hint: "[on|off]"),
        .init(name: "plan", description: "Enter or manage plan mode", hint: nil),
        .init(name: "flush", description: "Save session knowledge to memory now (experimental)", hint: nil),
        .init(name: "dream", description: "Run memory consolidation (experimental)", hint: nil),
        .init(name: "plugins", description: "Manage plugins (list, install, trust)", hint: "[list | install <src> | …]"),
        .init(name: "hooks", description: "Manage hooks (list, trust, enable/disable)", hint: nil),
        .init(name: "imagine", description: "Generate an image from a description", hint: "<description>"),
        .init(name: "imagine-video", description: "Generate a video from a description", hint: "<description>"),
        .init(name: "loop", description: "Run a prompt on a recurring interval", hint: "[interval] <prompt>"),
        .init(name: "mcps", description: "Open MCP servers management", hint: nil),
        .init(name: "feedback", description: "Report an issue or send feedback", hint: "[message]"),
        .init(name: "btw", description: "Send a quick aside to the agent", hint: "<message>"),
    ]

    /// Advertised commands unioned with the catalog, deduped by name (the live
    /// advertised entry wins for shared names like `/compact`), sorted for display.
    public static func merged(advertised: [SlashCommand]) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        for c in catalog { byName[c.name] = c }
        for c in advertised { byName[c.name] = c }
        return byName.values.sorted { $0.name < $1.name }
    }
}

/// Token / context-window usage for the session. `totalTokens` is the running
/// context consumed (streamed live in every `session/update._meta`); the rest is
/// the most-recent turn's breakdown (from the `session/prompt` result `_meta`).
public struct SessionUsage: Sendable, Equatable, Codable {
    public var totalTokens: Int
    public var contextWindow: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedReadTokens: Int?
    public var reasoningTokens: Int?

    public init(totalTokens: Int = 0, contextWindow: Int? = nil, inputTokens: Int? = nil,
                outputTokens: Int? = nil, cachedReadTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.reasoningTokens = reasoningTokens
    }

    public static let empty = SessionUsage()

    /// Fraction of the context window consumed (0...1), when the window is known.
    public var fraction: Double? {
        guard let w = contextWindow, w > 0 else { return nil }
        return min(1, Double(totalTokens) / Double(w))
    }

    /// True once at least one turn has reported usage.
    public var hasData: Bool { totalTokens > 0 }
}
