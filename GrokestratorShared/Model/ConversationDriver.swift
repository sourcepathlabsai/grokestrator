import Foundation
import GrokestratorCore
import UniformTypeIdentifiers

/// Single seam between the UI and the actual conversation source — local
/// in-process (`LiveConversationDriver`) or over the wire to a remote GKSS
/// (`RemoteConversationDriver`).
///
/// **Broadcast model (PR B):** the driver no longer hands the caller a per-call
/// stream of updates. Instead, the caller `subscribe()`s once and receives every
/// update for the Connection — including snapshots on join and updates
/// initiated from *other* clients. `send` is fire-and-forget.
public protocol ConversationDriver: Sendable {
    /// Fire a prompt at the underlying source. Updates flow out via `subscribe()`
    /// (which must be running on this driver), not back through this call.
    func send(_ prompt: String) async throws

    /// Open the Connection's broadcast stream. First event is `.snapshot` with
    /// the current transcript; subsequent events are `.update`s indefinitely,
    /// covering updates initiated from any client.
    func subscribe() async -> AsyncStream<ConnectionStreamEvent>

    /// Answer a pending permission request with the chosen ACP `optionId`.
    func respondToPermission(permissionId: String, optionId: String) async

    /// Answer a pending user question (`_x.ai/ask_user_question`). `answer` is the
    /// chosen option's label or the user's free-text answer; `questionIndex` is
    /// which question in the set. Parallels `respondToPermission`.
    func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async

    /// Stops the currently in-flight turn (Stop button). Best-effort: tells
    /// the underlying agent to stop, and locally unwinds the active stream so
    /// `turnComplete` rides through the broadcast and every connected device's
    /// spinner clears.
    func cancel() async

    /// The instance's capabilities (model, MCP servers, slash commands).
    func capabilities() async -> AgentCapabilities?

    /// Token / context usage for the session (inspector).
    func usage() async -> SessionUsage?

    /// Wipe the Connection's chat history. The cleared state arrives back as an
    /// empty `.snapshot` over `subscribe()`, so every connected device resets.
    func clearHistory() async

    /// `true` when media artifacts live on a *remote* host and must be fetched
    /// (a remote client). `false` for a local driver, where the transcript's
    /// file paths are directly readable and render without a fetch.
    var resolvesMediaRemotely: Bool { get }

    /// A small in-memory thumbnail / video poster (downscaled JPEG bytes),
    /// bounded to `maxDimension` pixels. `nil` on missing / timed-out fetch.
    func fetchMediaThumbnail(path: String, maxDimension: Int) async -> (data: Data, mimeType: String)?

    /// The full media file as a local file URL. Remote drivers stream it to a
    /// temp file (never holding it whole in memory); local drivers return the
    /// on-disk path directly. `nil` on missing / timed-out fetch.
    func fetchMediaFile(path: String) async -> (url: URL, mimeType: String)?

    /// A directly playable/streamable URL for a media artifact at host `path`.
    /// Remote drivers return an `http://` URL served by the host's media server
    /// (so `AVPlayer` streams it natively — progressive, seekable, no chunked
    /// transfer); local drivers return the on-disk `file://` URL. `nil` when the
    /// host isn't addressable yet.
    func mediaURL(forHostPath path: String) -> URL?
}

#if os(macOS)
/// Drives a conversation against the local Mac's own `GrokBuildManager` —
/// the in-process equivalent of `RemoteConversationDriver`. **Mac-only**:
/// iOS is a client-only app and never hosts its own grok processes; it always
/// drives over the wire via `RemoteConversationDriver`.
public struct LiveConversationDriver: ConversationDriver {
    public let manager: GrokBuildManager
    public let instanceID: UUID

    public init(manager: GrokBuildManager, instanceID: UUID) {
        self.manager = manager
        self.instanceID = instanceID
    }

    public func send(_ prompt: String) async throws {
        _ = try await manager.sendPrompt(to: instanceID, prompt: prompt)
    }

    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        // Race-tolerant: when a Connection has just been created, the UI's
        // `.task` may call this before `manager.startInstance` has set up the
        // underlying `GrokBuildConversation`. Wait for the conversation to
        // exist (polling every ~300ms) then forward all events. Cancellation
        // of the outer stream (view goes away) cancels the wait.
        let manager = self.manager
        let instanceID = self.instanceID
        return AsyncStream<ConnectionStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let inner = try? await manager.subscribe(to: instanceID) {
                        for await event in inner {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        break    // inner stream ended cleanly
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)   // retry until the instance is alive
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respondToPermission(permissionId: String, optionId: String) async {
        try? await manager.respondToPermission(for: instanceID, permissionId: permissionId, chosenOption: optionId)
    }

    public func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async {
        try? await manager.respondToUserQuestion(for: instanceID, questionId: questionId, questionIndex: questionIndex, answer: answer)
    }

    public func cancel() async {
        await manager.cancelPrompt(for: instanceID)
    }

    public func capabilities() async -> AgentCapabilities? {
        try? await manager.capabilities(for: instanceID)
    }

    public func usage() async -> SessionUsage? {
        await manager.usage(for: instanceID)
    }

    public func clearHistory() async {
        await manager.clearHistory(for: instanceID)
    }

    // Local host: the transcript's paths are readable directly, so media never
    // needs fetching for display. We still implement these for completeness.
    public var resolvesMediaRemotely: Bool { false }

    public func fetchMediaThumbnail(path: String, maxDimension: Int) async -> (data: Data, mimeType: String)? {
        guard let r = await MediaVendor.load(path: path, maxDimension: maxDimension) else { return nil }
        return (data: r.data, mimeType: r.mime)
    }

    public func fetchMediaFile(path: String) async -> (url: URL, mimeType: String)? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (url: url, mimeType: mime)
    }

    public func mediaURL(forHostPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif

// `MockConversationDriver` was removed once persisted Connections + the
// remote-server path covered every demo + dev workflow. If an offline
// scripted driver is ever wanted again, `git log -- GrokestratorShared/Model`
// has the last known-good shape.
