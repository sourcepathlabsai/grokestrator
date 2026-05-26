import Testing
import Foundation
@testable import GrokestratorCore

@Suite("Core Models")
struct ModelsTests {

    @Test("ServerAddress round-trips through Codable")
    func serverAddressCodable() throws {
        let addr = ServerAddress(name: "Dev Mac", tailscaleAddress: "100.64.0.1", port: 8080)
        let data = try JSONEncoder().encode(addr)
        let decoded = try JSONDecoder().decode(ServerAddress.self, from: data)
        #expect(decoded.name == "Dev Mac")
        #expect(decoded.port == 8080)
    }

    @Test("ManagedInstance has sensible defaults")
    func managedInstanceDefaults() {
        let inst = ManagedInstance(
            name: "primary",
            command: "/opt/homebrew/bin/grok",
            arguments: ["agent", "serve", "--stdio"],
            autoRestart: true
        )
        #expect(inst.status == .stopped)
        #expect(inst.autoRestart == true)
        #expect(inst.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test("ConnectionState helpers")
    func connectionStateHelpers() {
        #expect(ConnectionState.disconnected.isActive == false)
        #expect(ConnectionState.connected.isConnected == true)
        #expect(ConnectionState.connecting.isActive == true)
    }

    @Test("MultiServerSession starts disconnected")
    func multiServerSessionInitial() {
        let addr = ServerAddress(name: "Test", tailscaleAddress: "100.99.0.5", port: 8080)
        let session = MultiServerSession(serverAddress: addr)
        #expect(session.isConnected == false)
        #expect(session.connection.state == .disconnected)
    }
}
