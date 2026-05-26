import Foundation

/// Simple file-based persistence using JSON files in a directory.
/// Suitable for MVP / single-user scenarios. The directory is supplied by the
/// caller (Mac app uses ~/Library/Application Support/Grokestrator, iOS uses
/// its own container, tests use a temp dir).
///
/// This implementation is an actor for safe concurrent access.
public actor FilePersistence: PersistenceProtocol {
    private let baseDirectory: URL
    private let fileManager = FileManager.default

    private let serverAddressesURL: URL
    private let conversationsDir: URL
    private let serverConfigURL: URL
    private let clientConfigURL: URL

    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        self.serverAddressesURL = baseDirectory.appendingPathComponent("servers.json")
        self.conversationsDir = baseDirectory.appendingPathComponent("conversations")
        self.serverConfigURL = baseDirectory.appendingPathComponent("server-config.json")
        self.clientConfigURL = baseDirectory.appendingPathComponent("client-config.json")

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
    }

    // MARK: - Server Addresses

    public func loadServerAddresses() async throws -> [ServerAddress] {
        try await loadJSON([ServerAddress].self, from: serverAddressesURL) ?? []
    }

    public func saveServerAddress(_ address: ServerAddress) async throws {
        var addresses = try await loadServerAddresses()
        if let idx = addresses.firstIndex(where: { $0.id == address.id }) {
            addresses[idx] = address
        } else {
            addresses.append(address)
        }
        try await writeJSON(addresses, to: serverAddressesURL)
    }

    public func deleteServerAddress(id: UUID) async throws {
        var addresses = try await loadServerAddresses()
        addresses.removeAll { $0.id == id }
        try await writeJSON(addresses, to: serverAddressesURL)
    }

    // MARK: - Conversations

    public func loadConversations(forServer serverID: UUID) async throws -> [Conversation] {
        let url = conversationsDir.appendingPathComponent("\(serverID.uuidString).json")
        return try await loadJSON([Conversation].self, from: url) ?? []
    }

    public func saveConversation(_ conversation: Conversation) async throws {
        let url = conversationsDir.appendingPathComponent("\(conversation.serverID.uuidString).json")
        var convos = try await loadConversations(forServer: conversation.serverID)
        if let idx = convos.firstIndex(where: { $0.id == conversation.id }) {
            convos[idx] = conversation
        } else {
            convos.append(conversation)
        }
        try await writeJSON(convos, to: url)
    }

    public func deleteConversation(id: UUID) async throws {
        // For simplicity in MVP we scan all server files (small data)
        let allServerFiles = try fileManager.contentsOfDirectory(at: conversationsDir, includingPropertiesForKeys: nil)
        for file in allServerFiles where file.pathExtension == "json" {
            if var convos: [Conversation] = try await loadJSON([Conversation].self, from: file) {
                let before = convos.count
                convos.removeAll { $0.id == id }
                if convos.count != before {
                    try await writeJSON(convos, to: file)
                    return
                }
            }
        }
    }

    // MARK: - Messages (per conversation, simple append-only files for MVP)

    public func loadMessages(forConversation conversationID: UUID, limit: Int?) async throws -> [Message] {
        let url = conversationsDir.appendingPathComponent("messages-\(conversationID.uuidString).json")
        let all = try await loadJSON([Message].self, from: url) ?? []
        if let limit = limit, all.count > limit {
            return Array(all.suffix(limit))
        }
        return all
    }

    public func saveMessage(_ message: Message) async throws {
        let url = conversationsDir.appendingPathComponent("messages-\(message.conversationID.uuidString).json")
        var msgs = try await loadJSON([Message].self, from: url) ?? []
        msgs.append(message)
        try await writeJSON(msgs, to: url)
    }

    // MARK: - Server / Client Config

    public func loadServerConfiguration() async throws -> ServerConfiguration? {
        try await loadJSON(ServerConfiguration.self, from: serverConfigURL)
    }

    public func saveServerConfiguration(_ config: ServerConfiguration) async throws {
        try await writeJSON(config, to: serverConfigURL)
    }

    public func loadClientConfiguration() async throws -> ClientConfiguration {
        try await loadJSON(ClientConfiguration.self, from: clientConfigURL) ?? ClientConfiguration()
    }

    public func saveClientConfiguration(_ config: ClientConfiguration) async throws {
        try await writeJSON(config, to: clientConfigURL)
    }

    // MARK: - Helpers

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) async throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
