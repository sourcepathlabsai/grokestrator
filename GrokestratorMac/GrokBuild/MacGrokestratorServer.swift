import Foundation
import GrokestratorCore

/// Server side of Grokestrator: a `GrokestratorListener` bridged to the local
/// `GrokBuildManager`. Translates inbound `GrokestratorRequest`s into manager
/// calls and forwards manager streams back to remote clients as
/// `GrokestratorEvent`s. Tailscale handles encryption/auth at the transport.
///
/// Lifecycle: created on app launch, idle until `start(port:)` is called from
/// the Settings UI toggle.
public actor MacGrokestratorServer {
    /// Mirrors the listener's state with an Equatable Sendable shape the UI can observe.
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    private var listener: GrokestratorListener?
    private let manager: GrokBuildManager
    private var instanceListSubscribers: [GrokestratorListener.ClientID] = []
    private var lastBroadcastInstances: [ManagedInstance] = []

    public init(manager: GrokBuildManager) {
        self.manager = manager
    }

    /// Opens the listener on `port`. Idempotent: returns the current state if
    /// already listening. Errors surface in `state = .failed(...)`.
    public func start(port: UInt16) async throws {
        if case .listening = state { return }
        state = .starting

        // The handler captures `self` weakly to avoid a strong cycle through the
        // listener's stored closure; reaches back via methods.
        let listener = GrokestratorListener { [weak self] request, clientID, outbox in
            await self?.handle(request: request, from: clientID, outbox: outbox)
        }
        do {
            try await listener.start(port: port)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        self.listener = listener
        let bound = await listener.state
        if case .listening(let p) = bound { state = .listening(port: p) }
    }

    /// Stops the listener; all connected clients disconnect.
    public func stop() async {
        await listener?.stop()
        listener = nil
        instanceListSubscribers.removeAll()
        state = .stopped
    }

    // MARK: - Request dispatch

    /// Routes one inbound request through the manager and emits matching events.
    private func handle(request: GrokestratorRequest,
                        from clientID: GrokestratorListener.ClientID,
                        outbox: GrokestratorListener.ListenerOutbox) async {
        switch request {
        case .listInstances:
            instanceListSubscribers.append(clientID)
            let list = await manager.currentInstances()
            lastBroadcastInstances = list
            await outbox.toClient(.instancesUpdated(list), clientID)

        case .grokBuild(let req):
            await handleGrokBuild(req, from: clientID, outbox: outbox)

        default:
            // Unhandled today (launchInstance / stopInstance / persistence reads
            // etc.) — surface a structured error so the client can show it.
            await outbox.toClient(.error(.notImplemented("\(request)")), clientID)
        }
    }

    private func handleGrokBuild(_ req: GrokBuildRequest,
                                 from clientID: GrokestratorListener.ClientID,
                                 outbox: GrokestratorListener.ListenerOutbox) async {
        switch req {
        case .startPrompt(let instanceID, let prompt, let promptID):
            let pid = promptID ?? UUID()
            do {
                let stream = try await manager.sendPrompt(to: instanceID, prompt: prompt)
                // Fan updates out as conversationUpdate events, sent to this client.
                Task {
                    for await update in stream {
                        await outbox.toClient(
                            .grokBuild(.conversationUpdate(instanceID: instanceID, promptID: pid, update: update)),
                            clientID
                        )
                        if case .turnComplete = update { break }
                    }
                    // After the stream ends, push fresh usage so the remote inspector updates.
                    if let usage = await self.manager.usage(for: instanceID) {
                        await outbox.toClient(.grokBuild(.usageUpdated(instanceID: instanceID, usage: usage)), clientID)
                    }
                }
            } catch {
                await outbox.toClient(.grokBuild(.error(instanceID: instanceID, promptID: pid, message: error.localizedDescription)), clientID)
            }

        case .respondToPermission(let instanceID, _, let permissionId, let chosenOption):
            try? await manager.respondToPermission(for: instanceID, permissionId: permissionId, chosenOption: chosenOption)

        case .getCapabilities(let instanceID):
            if let caps = try? await manager.capabilities(for: instanceID) {
                await outbox.toClient(.grokBuild(.capabilitiesUpdated(instanceID: instanceID, capabilities: caps)), clientID)
            }

        case .getUsage(let instanceID):
            if let usage = await manager.usage(for: instanceID) {
                await outbox.toClient(.grokBuild(.usageUpdated(instanceID: instanceID, usage: usage)), clientID)
            }

        case .cancelPrompt, .sendToolResult, .getPromptState:
            // Not exercised by the MVP client; safe to ignore.
            break
        }
    }

    /// Pushes a fresh instances list to every subscriber. The server-owning Mac
    /// app calls this when the local instance list changes (launched/stopped).
    public func broadcastInstancesIfChanged() async {
        guard listener != nil else { return }
        let list = await manager.currentInstances()
        guard list != lastBroadcastInstances else { return }
        lastBroadcastInstances = list
        await listener?.broadcast(.instancesUpdated(list))
    }
}

// MARK: - Conveniences

public extension GrokestratorError {
    /// Used when a request reaches the server but isn't implemented yet.
    static func notImplemented(_ what: String) -> GrokestratorError {
        .protocolError("not implemented: \(what)")
    }
}
