import Testing
import Foundation
@testable import GrokestratorCore

/// Verifies the shared-session model end-to-end on the *client* side: a
/// `GrokBuildClientSession.subscribe()` opens a stream, a wire
/// `historySnapshot` event becomes a `.snapshot` to the subscriber, and a
/// subsequent `conversationUpdate` event becomes a `.update`. Two parallel
/// subscribers both see the same events — proving the broadcast wiring.
@Suite("Broadcast subscription (client-side)")
struct BroadcastSubscriptionTests {

    @Test func snapshotThenUpdateFlowsToSubscriber() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let session = await client.grokBuildSession(for: instanceID, on: serverSession)

        // Open a subscription. (Sends `.subscribeToConnection` request.)
        let stream = await session.subscribe()
        var iter = stream.makeAsyncIterator()

        // Server pushes a snapshot first.
        let turns: [AgentTurn] = [
            AgentTurn(userPrompt: "hello", messages: [
                AgentMessage(role: .assistant, content: "hi there")
            ])
        ]
        await transport.simulateIncomingEvent(
            .grokBuild(.historySnapshot(instanceID: instanceID, turns: turns)),
            from: serverSession.id
        )
        guard case .snapshot(let received) = await iter.next() else {
            Issue.record("expected .snapshot first"); return
        }
        #expect(received.count == 1)
        #expect(received.first?.userPrompt == "hello")

        // Then a live update.
        await transport.simulateIncomingEvent(
            .grokBuild(.conversationUpdate(
                instanceID: instanceID, promptID: UUID(),
                update: .message("the answer is 42", metadata: nil))),
            from: serverSession.id
        )
        guard case .update(.message(let text, _)) = await iter.next() else {
            Issue.record("expected .update(.message)"); return
        }
        #expect(text == "the answer is 42")

        // The session should have sent exactly one outbound request: the subscribe.
        let sent = await transport.sentRequests[serverSession.id] ?? []
        #expect(sent.count == 1)
        if case .grokBuild(.subscribeToConnection(let id)) = sent.first {
            #expect(id == instanceID)
        } else {
            Issue.record("expected subscribeToConnection")
        }
    }

    @Test func twoSubscribersBothReceiveTheSameUpdate() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let session = await client.grokBuildSession(for: instanceID, on: serverSession)

        let a = await session.subscribe()
        let b = await session.subscribe()
        var ia = a.makeAsyncIterator()
        var ib = b.makeAsyncIterator()

        // Both subscriptions registered → server pushes one update → both receive.
        await transport.simulateIncomingEvent(
            .grokBuild(.conversationUpdate(
                instanceID: instanceID, promptID: UUID(),
                update: .progressNote("scanning", phase: "scan", metadata: nil))),
            from: serverSession.id
        )

        let eventA = await ia.next()
        let eventB = await ib.next()
        guard case .update(.progressNote(let textA, _, _)) = eventA,
              case .update(.progressNote(let textB, _, _)) = eventB else {
            Issue.record("expected progressNote on both subscribers"); return
        }
        #expect(textA == "scanning")
        #expect(textB == "scanning")
    }

    // MARK: - helpers

    /// Wires a client through an `InMemoryGrokestratorTransport`, with one
    /// connected server. Mirrors the helper in `GrokestratorClientTests`.
    private func makeConnectedClient() async -> (GrokestratorClient, MultiServerSession, InMemoryGrokestratorTransport) {
        let transport = InMemoryGrokestratorTransport()
        let client = GrokestratorClient()
        let address = ServerAddress(name: "Test", tailscaleAddress: "127.0.0.1", port: 8080)
        let session = await client.addServer(address, displayName: "Test", transport: transport)
        await client.connect(to: session.id)
        return (client, session, transport)
    }
}
