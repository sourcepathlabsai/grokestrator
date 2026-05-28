import Testing
import Foundation
@testable import GrokestratorCore

/// End-to-end loopback test: a `GrokestratorListener` and a
/// `NetworkGrokestratorTransport` exchange one request/event over a real TCP
/// socket on 127.0.0.1. Confirms the wire frames + JSON decode round-trip.
@Suite("Network transport (loopback)")
struct NetworkTransportTests {

    @Test func listInstancesRoundTripsOverTCP() async throws {
        // Server: respond to listInstances with an empty list.
        let listener = GrokestratorListener { request, clientID, outbox in
            if case .listInstances = request {
                await outbox.toClient(.instancesUpdated([]), clientID)
            }
        }
        // Port 0 → kernel picks a free port; we read it back below.
        try await listener.start(port: 0)
        guard case .listening(let port) = await listener.state, port != 0 else {
            Issue.record("listener never reached .listening")
            return
        }

        // Client.
        let serverID = UUID()
        let transport = NetworkGrokestratorTransport(host: "127.0.0.1", port: port, serverID: serverID)

        // Bridge incoming events to an AsyncStream we can pull from synchronously.
        let (events, cont) = AsyncStream<GrokestratorEvent>.makeStream()
        await transport.setEventHandler { event, _ in cont.yield(event) }
        try await transport.connect()
        try await transport.send(.listInstances, serverID: serverID)

        // Read the first event with a generous timeout.
        let event = try await firstEvent(events, timeout: 3)
        guard case .instancesUpdated(let list) = event else {
            Issue.record("unexpected event: \(event)"); return
        }
        #expect(list.isEmpty)

        await transport.disconnect()
        await listener.stop()
    }

    /// Returns the first event or throws on timeout (so a stuck wire surfaces fast).
    private func firstEvent(_ stream: AsyncStream<GrokestratorEvent>, timeout seconds: Double) async throws -> GrokestratorEvent {
        try await withThrowingTaskGroup(of: GrokestratorEvent.self) { group in
            group.addTask {
                for await event in stream { return event }
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "stream ended without event"])
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout"])
            }
            let event = try await group.next()!
            group.cancelAll()
            return event
        }
    }
}
