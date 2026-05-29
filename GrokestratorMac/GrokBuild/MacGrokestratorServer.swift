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
                .filter { $0.shared && !$0.archived }    // privacy + archive boundary
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
        case .startPrompt(let instanceID, let prompt, _):
            // Fire-and-forget in the broadcast model: updates flow out to every
            // subscriber of this Connection (including the requesting client,
            // assuming they also issued `subscribeToConnection`). After the
            // turn ends we push fresh usage so all remote inspectors update.
            do {
                _ = try await manager.sendPrompt(to: instanceID, prompt: prompt)
            } catch {
                await outbox.toClient(.grokBuild(.error(instanceID: instanceID, promptID: nil, message: error.localizedDescription)), clientID)
            }

        case .subscribeToConnection(let instanceID):
            // Open a broadcast subscription on the conversation, forward each
            // event to this specific client. The conversation actor delivers a
            // `.snapshot` first, then `.update`s indefinitely. The forwarding
            // Task ends when the client disconnects (we don't currently track
            // per-(client,instance) cancellation — a follow-up).
            do {
                let stream = try await manager.subscribe(to: instanceID)
                Task {
                    for await event in stream {
                        switch event {
                        case .snapshot(let turns):
                            await outbox.toClient(.grokBuild(.historySnapshot(instanceID: instanceID, turns: turns)), clientID)
                        case .update(let u):
                            await outbox.toClient(.grokBuild(.conversationUpdate(instanceID: instanceID, promptID: UUID(), update: u)), clientID)
                        }
                    }
                }
            } catch {
                await outbox.toClient(.grokBuild(.error(instanceID: instanceID, promptID: nil, message: error.localizedDescription)), clientID)
            }

        case .unsubscribeFromConnection:
            // The stream terminates naturally when the conversation's subscriber
            // continuation drops; nothing to do here today (single subscription
            // per client is the MVP). A future iteration can carry a subscription
            // token to scope this.
            break

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

        case .cancelPrompt(let instanceID, _):
            // A remote client (iPad / another Mac) clicked Stop. Forward to
            // the local manager, which unwinds the active stream and
            // broadcasts `turnComplete` to every subscriber (so the spinner
            // clears on *every* connected device, not just the one that
            // pressed the button).
            await manager.cancelPrompt(for: instanceID)

        case .fetchMedia(let instanceID, let path, let maxDimension, let requestID):
            // Off the actor so a large file / AVFoundation work doesn't block
            // other requests. Thumbnails reply in one chunk; full files stream
            // in 512KB chunks read from disk, correlated by requestID.
            Task.detached {
                if let maxDimension {
                    let thumb = await MediaVendor.thumbnail(path: path, maxDimension: maxDimension)
                    let chunk = thumb.map { MediaChunk(sequence: 0, isFinal: true, mimeType: $0.mime, data: $0.data) }
                    await outbox.toClient(.grokBuild(.mediaData(instanceID: instanceID, requestID: requestID, chunk: chunk)), clientID)
                } else {
                    await MediaVendor.streamFull(path: path) { chunk in
                        await outbox.toClient(.grokBuild(.mediaData(instanceID: instanceID, requestID: requestID, chunk: chunk)), clientID)
                    }
                }
            }

        case .clearHistory(let instanceID):
            // A client (this Mac or a remote iPad) asked to wipe the transcript.
            // The manager clears the persisted history and broadcasts an empty
            // snapshot, which the subscribe forwarder above relays to every
            // connected device as a `historySnapshot([])` — so all transcripts
            // reset together.
            await manager.clearHistory(for: instanceID)

        case .sendToolResult, .getPromptState:
            // Not exercised by the MVP client; safe to ignore.
            break
        }
    }

    /// Pushes a fresh instances list to every subscriber. The server-owning Mac
    /// app calls this when the local instance list changes (launched/stopped).
    public func broadcastInstancesIfChanged() async {
        guard listener != nil else { return }
        let list = await manager.currentInstances()
            .filter { $0.shared && !$0.archived }
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
