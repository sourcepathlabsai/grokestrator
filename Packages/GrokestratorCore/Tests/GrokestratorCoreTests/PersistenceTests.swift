import Testing
import Foundation
@testable import GrokestratorCore

@Suite("FilePersistence (in-memory dir)")
struct PersistenceTests {

    @Test("Round-trip server address and client config")
    func basicRoundTrip() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokestrator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let persistence = try FilePersistence(baseDirectory: temp)

        let addr = ServerAddress(name: "Test Server", tailscaleAddress: "100.64.12.34", port: 9090)
        try await persistence.saveServerAddress(addr)

        let loaded = try await persistence.loadServerAddresses()
        #expect(loaded.count == 1)
        #expect(loaded.first?.tailscaleAddress == "100.64.12.34")

        var clientCfg = try await persistence.loadClientConfiguration()
        clientCfg.autoReconnect = false
        try await persistence.saveClientConfiguration(clientCfg)

        let loadedCfg = try await persistence.loadClientConfiguration()
        #expect(loadedCfg.autoReconnect == false)
    }

    @Test("Conversation + message persistence")
    func conversationAndMessages() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokestrator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let persistence = try FilePersistence(baseDirectory: temp)
        let serverID = UUID()

        var convo = Conversation(serverID: serverID, title: "First test thread")
        try await persistence.saveConversation(convo)

        let msg = Message(conversationID: convo.id, role: .user, content: "Hello from test")
        try await persistence.saveMessage(msg)

        let convos = try await persistence.loadConversations(forServer: serverID)
        #expect(convos.count == 1)

        let msgs = try await persistence.loadMessages(forConversation: convo.id, limit: nil)
        #expect(msgs.count == 1)
        #expect(msgs.first?.content == "Hello from test")
    }
}
