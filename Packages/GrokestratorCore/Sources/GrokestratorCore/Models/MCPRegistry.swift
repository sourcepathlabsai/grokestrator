import Foundation

/// How the host reaches an MCP server. `stdio` spawns a subprocess (the common case
/// — npx/uvx/python servers); `http` connects to a Streamable-HTTP / SSE endpoint.
/// Discriminated by `kind` for a hand-editable `mcp.json`.
public enum MCPTransport: Codable, Hashable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String])

    private enum CodingKeys: String, CodingKey { case kind, command, args, env, url, headers }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let command, let args, let env):
            try c.encode("stdio", forKey: .kind)
            try c.encode(command, forKey: .command)
            try c.encode(args, forKey: .args)
            if !env.isEmpty { try c.encode(env, forKey: .env) }
        case .http(let url, let headers):
            try c.encode("http", forKey: .kind)
            try c.encode(url, forKey: .url)
            if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "stdio" {
        case "http":
            self = .http(url: try c.decode(String.self, forKey: .url),
                         headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:])
        default:
            self = .stdio(command: try c.decodeIfPresent(String.self, forKey: .command) ?? "",
                          args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                          env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:])
        }
    }

    public var isStdio: Bool { if case .stdio = self { return true }; return false }
}

/// A host-configured MCP server in Grokestrator's own registry — model-agnostic and
/// independent of grok's config. grok Nodes get the granted subset injected into
/// `session/new`; API-brain Nodes reach them through the in-app MCP client (slice 2).
public struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var transport: MCPTransport
    public init(id: UUID = UUID(), name: String, transport: MCPTransport) {
        self.id = id; self.name = name; self.transport = transport
    }
}

/// The host-local library of MCP servers (`mcp.json`). The harness owns this — one
/// source of truth that both grok and API brains resolve against. Per-Node access is
/// a *grant* (`ManagedInstance.grantedMCPServerIDs`) that filters this set.
public struct MCPRegistry: Codable, Hashable, Sendable {
    public var servers: [MCPServerConfig]
    public init(servers: [MCPServerConfig] = []) { self.servers = servers }

    public func server(_ id: UUID) -> MCPServerConfig? { servers.first { $0.id == id } }

    /// The servers a Node may use given its grant: `nil` ⇒ all (unrestricted, like
    /// `ToolPolicy.allowed`); otherwise the subset whose ids are listed (order and
    /// existence filtered against the current registry, so a stale id is ignored).
    public func granted(to ids: [UUID]?) -> [MCPServerConfig] {
        guard let ids else { return servers }
        let set = Set(ids)
        return servers.filter { set.contains($0.id) }
    }
}
