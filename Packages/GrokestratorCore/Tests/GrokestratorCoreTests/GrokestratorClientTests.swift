import Testing
import Foundation
@testable import GrokestratorCore

@Suite("GrokestratorClient + GrokBuildClientSession (end-to-end with mock transport)")
struct GrokestratorClientTests {

    // MARK: - Helpers

    private func makeConnectedClient() async -> (client: GrokestratorClient, serverSession: MultiServerSession, transport: InMemoryGrokestratorTransport) {
        let transport = InMemoryGrokestratorTransport()
        let client = GrokestratorClient()

        let address = ServerAddress(name: "Test Server", tailscaleAddress: "100.64.0.1", port: 1234)
        let serverSession = client.addServer(address, transport: transport)
        await client.connect(to: serverSession.id)

        return (client, serverSession, transport)
    }

    // MARK: - Tests

    @Test("Basic prompt flow with progress notes and final message")
    func basicPromptFlow() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let buildSession = client.grokBuildSession(for: instanceID, on: serverSession)

        // Start prompt
        _ = try await buildSession.startPrompt("Review the architecture")

        // Simulate realistic server responses
        let progress1 = ConversationUpdate.progressNote("Analyzing modules...", phase: "scan", metadata: nil)
        let progress2 = ConversationUpdate.progressNote("Found 2 issues", phase: "analysis", metadata: nil)
        let finalMessage = ConversationUpdate.message("Refactor recommendation: Extract networking layer.", metadata: nil)
        let completion = ConversationUpdate.turnComplete(finalAnswer: "Done.")

        let promptID = UUID() // We don't have the real one easily here, but for simulation it's fine

        transport.simulateIncomingEvent(.grokBuild(.conversationUpdate(instanceID: instanceID, promptID: promptID, update: progress1)), from: serverSession.id)
        transport.simulateIncomingEvent(.grokBuild(.conversationUpdate(instanceID: instanceID, promptID: promptID, update: progress2)), from: serverSession.id)
        transport.simulateIncomingEvent(.grokBuild(.conversationUpdate(instanceID: instanceID, promptID: promptID, update: finalMessage)), from: serverSession.id)
        transport.simulateIncomingEvent(.grokBuild(.conversationUpdate(instanceID: instanceID, promptID: promptID, update: completion)), from: serverSession.id)

        // Verify the client recorded the initial startPrompt request
        let sent = await transport.sentRequests[serverSession.id] ?? []
        #expect(sent.count == 1)
        if case .grokBuild(let buildReq) = sent[0],
           case .startPrompt(let instID, let text, _) = buildReq {
            #expect(instID == instanceID)
            #expect(text == "Review the architecture")
        } else {
            Issue.record("Expected startPrompt request")
        }
    }

    @Test("Tool call roundtrip with proper request verification")
    func toolCallRoundtrip() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let buildSession = client.grokBuildSession(for: instanceID, on: serverSession)

        _ = try await buildSession.startPrompt("Run static analysis")

        // Server requests a tool
        let toolCall = ToolCallInfo(id: "tool-42", toolName: "run_swiftlint", arguments: ["path": "Sources"])
        transport.simulateIncomingEvent(
            .grokBuild(.conversationUpdate(
                instanceID: instanceID,
                promptID: UUID(),
                update: .toolCallRequested(toolCall)
            )),
            from: serverSession.id
        )

        // Client sends result back
        try await buildSession.sendToolResult(
            promptID: UUID(),
            toolCallId: "tool-42",
            result: "{\"violations\": 3}",
            isError: false
        )

        // Assert the exact request that was sent
        let sent = await transport.sentRequests[serverSession.id] ?? []
        #expect(sent.count == 2) // start + tool result

        if case .grokBuild(let buildReq) = sent[1],
           case .sendToolResult(let instID, _, let toolCallId, let result, let isError) = buildReq {
            #expect(instID == instanceID)
            #expect(toolCallId == "tool-42")
            #expect(result == "{\"violations\": 3}")
            #expect(isError == false)
        } else {
            Issue.record("Expected sendToolResult request")
        }
    }

    @Test("Cancellation sends correct request and cleans up")
    func promptCancellation() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let buildSession = client.grokBuildSession(for: instanceID, on: serverSession)

        _ = try await buildSession.startPrompt("Long running analysis")

        // Cancel it
        try await buildSession.cancelPrompt(promptID: UUID())

        let sent = await transport.sentRequests[serverSession.id] ?? []
        #expect(sent.count == 2)

        if case .grokBuild(let buildReq) = sent[1],
           case .cancelPrompt(let instID, _) = buildReq {
            #expect(instID == instanceID)
        } else {
            Issue.record("Expected cancelPrompt request")
        }
    }

    @Test("Instance death invalidates the session and prevents further prompts")
    func instanceDeath() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let buildSession = client.grokBuildSession(for: instanceID, on: serverSession)

        _ = try await buildSession.startPrompt("Background job")

        transport.simulateIncomingEvent(
            .grokBuild(.instanceDied(instanceID: instanceID, exitCode: 137)),
            from: serverSession.id
        )

        await #expect(throws: GrokestratorError.sessionInvalidated) {
            _ = try await buildSession.startPrompt("New prompt after death")
        }
    }

    @Test("Multiple prompts on the same instance are tracked separately")
    func multipleConcurrentPrompts() async throws {
        let (client, serverSession, transport) = await makeConnectedClient()
        let instanceID = UUID()
        let buildSession = client.grokBuildSession(for: instanceID, on: serverSession)

        _ = try await buildSession.startPrompt("Prompt A")
        _ = try await buildSession.startPrompt("Prompt B")

        // Both start requests should be recorded
        let sent = await transport.sentRequests[serverSession.id] ?? []
        let startRequests = sent.filter {
            if case .grokBuild(let r) = $0, case .startPrompt = r { return true }
            return false
        }
        #expect(startRequests.count == 2)
    }

    @Test("Per-server event stream receives lifecycle events")
    func perServerEvents() async throws {
        let transport = InMemoryGrokestratorTransport()
        let client = GrokestratorClient()

        let address = ServerAddress(name: "Isolated", tailscaleAddress: "100.64.0.2", port: 1234)
        let serverSession = client.addServer(address, transport: transport)

        var receivedEvents: [GrokestratorClient.ClientEvent] = []
        let serverEvents = client.events(for: serverSession.id)

        // Start listening in a task
        let listenTask = Task {
            for await event in serverEvents {
                receivedEvents.append(event)
                if receivedEvents.count >= 2 { break }
            }
        }

        await client.connect(to: serverSession.id)
        await client.disconnect(from: serverSession.id, reason: "Test disconnect")

        // Give the stream a moment
        try await Task.sleep(for: .milliseconds(50))

        #expect(receivedEvents.contains { if case .serverConnected = $0 { return true }; return false })
        #expect(receivedEvents.contains { if case .serverDisconnected = $0 { return true }; return false })

        listenTask.cancel()
    }
}
