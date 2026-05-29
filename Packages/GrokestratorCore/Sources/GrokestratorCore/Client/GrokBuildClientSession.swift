import Foundation

/// Higher-level client abstraction for driving a remote Grok Build instance.
///
/// This type aims to provide an experience similar to the local `GrokBuildConversation`
/// while hiding the details of the `GrokestratorProtocol` and transport layer.
///
/// Usage:
/// - Create via `GrokestratorClient` (preferred) or directly with a send closure.
/// - Call `startPrompt(...)` to drive the remote agent.
/// - Listen to the returned `AsyncStream<ConversationUpdate>`.
/// - Use `sendToolResult(...)` to continue tool-using agents.
public actor GrokBuildClientSession {
    public let instanceID: UUID

    /// Function used to send control-plane requests. Injected by the owning client.
    private let sendRequest: @Sendable (GrokestratorRequest) async throws -> Void

    private var activePrompts: [UUID: AsyncStream<ConversationUpdate>.Continuation] = [:]
    private var pendingToolCallsByPrompt: [UUID: [ToolCallInfo]] = [:]
    private var isValid = true

    /// Broadcast subscribers — the wire-side equivalent of
    /// `GrokBuildConversation.subscribe()`. Server delivers a `historySnapshot`
    /// then ongoing `conversationUpdate` events; this session translates those
    /// inbound events into `ConnectionStreamEvent`s and fans them to all UI
    /// subscribers (typically one per remote view).
    private var broadcastSubscribers: [UUID: AsyncStream<ConnectionStreamEvent>.Continuation] = [:]

    /// Cached capabilities/usage so the inspector renders something on first
    /// open even before the first `*Updated` event arrives. Refreshed on demand.
    private var cachedCapabilities: AgentCapabilities = .empty
    private var cachedUsage: SessionUsage = .empty

    /// Single in-flight continuation per kind. Resolved by the matching
    /// `*Updated` event (with the fresh snapshot) or by the timeout task (with the
    /// cached snapshot). Non-throwing — we always resolve so the UI never stalls.
    private var capContinuation: CheckedContinuation<AgentCapabilities, Never>?
    private var usageContinuation: CheckedContinuation<SessionUsage, Never>?

    /// State for one in-flight media transfer. Thumbnails accumulate in memory
    /// (they're small); full files stream straight to a temp file on disk so a
    /// large video is never held whole in memory client-side.
    private final class MediaTransfer {
        enum Mode { case memory; case file(ext: String) }
        let mode: Mode
        var mime: String?
        var data = Data()          // .memory
        var handle: FileHandle?    // .file
        var url: URL?              // .file
        var chunks = 0
        var bytes = 0
        init(mode: Mode) { self.mode = mode }
    }
    private var transfers: [UUID: MediaTransfer] = [:]
    private var dataConts: [UUID: CheckedContinuation<(data: Data, mimeType: String)?, Never>] = [:]
    private var fileConts: [UUID: CheckedContinuation<(url: URL, mimeType: String)?, Never>] = [:]
    /// Per-fetch inactivity watchdog — re-armed on each chunk so a slow but
    /// progressing large transfer isn't killed, only a truly stalled one.
    private var mediaWatchdogs: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    /// Optional callback used to register active prompts with the parent client
    /// so that prompt-scoped events can be routed precisely.
    private let registerPrompt: (@Sendable (UUID, UUID) -> Void)?

    /// Create a session for a specific remote Grok Build instance.
    ///
    /// - Parameter instanceID: The ID of the remote instance this session talks to.
    /// - Parameter sendRequest: Closure that sends a `GrokestratorRequest` over the control plane.
    /// - Parameter registerPrompt: Optional callback so the owning `GrokestratorClient`
    ///   can maintain a `promptID → instanceID` map for accurate event routing.
    public init(
        instanceID: UUID,
        sendRequest: @escaping @Sendable (GrokestratorRequest) async throws -> Void,
        registerPrompt: (@Sendable (UUID, UUID) -> Void)? = nil
    ) {
        self.instanceID = instanceID
        self.sendRequest = sendRequest
        self.registerPrompt = registerPrompt
    }

    // MARK: - Public API

    // `StartedPrompt` (the per-prompt stream wrapper) was removed when the
    // broadcast model replaced per-call streams. See `subscribe()`.

    /// Fires a prompt at the remote instance. **Fire-and-forget** in the
    /// broadcast model: updates flow back via `subscribe()`, not through this
    /// call. Returns the prompt's stable id so the caller can cancel later.
    @discardableResult
    public func startPrompt(_ text: String) async throws -> UUID {
        guard isValid else { throw GrokestratorError.sessionInvalidated }
        let promptID = UUID()
        let request = GrokBuildRequest.startPrompt(
            instanceID: instanceID, prompt: text, promptID: promptID
        )
        try await sendRequest(.grokBuild(request))
        registerPrompt?(promptID, instanceID)
        return promptID
    }

    /// Subscribe to the remote Connection's broadcast stream. Sends a
    /// `subscribeToConnection` request; the server replies with `historySnapshot`
    /// then forwards every `conversationUpdate` for this Connection (initiated
    /// by *any* client). Translated into `ConnectionStreamEvent`s.
    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        let (stream, cont) = AsyncStream<ConnectionStreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        broadcastSubscribers[token] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeBroadcastSubscriber(token) }
        }
        // Ask the server to start delivering. Failure to send leaves the stream
        // open but empty — the UI shows whatever the cache has.
        try? await sendRequest(.grokBuild(.subscribeToConnection(instanceID: instanceID)))
        return stream
    }

    private func removeBroadcastSubscriber(_ token: UUID) {
        broadcastSubscribers.removeValue(forKey: token)
    }

    private func broadcastEvent(_ event: ConnectionStreamEvent) {
        for (_, cont) in broadcastSubscribers { cont.yield(event) }
    }

    /// Sends the result of a tool call back to the remote agent.
    public func sendToolResult(
        promptID: UUID,
        toolCallId: String,
        result: String,
        isError: Bool = false
    ) async throws {
        guard isValid else {
            throw GrokestratorError.sessionInvalidated
        }
        // Best-effort local cleanup. The broadcast model means we don't track
        // per-prompt active streams anymore — the server is the source of truth.
        pendingToolCallsByPrompt[promptID]?.removeAll { $0.id == toolCallId }

        let request = GrokBuildRequest.sendToolResult(
            instanceID: instanceID,
            promptID: promptID,
            toolCallId: toolCallId,
            result: result,
            isError: isError
        )

        try await sendRequest(.grokBuild(request))
    }

    /// Cancels an in-progress prompt. Best-effort: the server will stop the
    /// turn and broadcast a `.turnComplete` to every subscriber.
    public func cancelPrompt(promptID: UUID) async throws {
        guard isValid else { throw GrokestratorError.sessionInvalidated }
        pendingToolCallsByPrompt.removeValue(forKey: promptID)
        try? await sendRequest(.grokBuild(.cancelPrompt(instanceID: instanceID, promptID: promptID)))
    }

    /// Asks the server to wipe this Connection's chat history. Best-effort and
    /// fire-and-forget: the server clears the transcript and pushes an empty
    /// `historySnapshot`, which arrives via `subscribe()` and resets the UI.
    public func clearHistory() async throws {
        guard isValid else { throw GrokestratorError.sessionInvalidated }
        try? await sendRequest(.grokBuild(.clearHistory(instanceID: instanceID)))
    }

    /// Returns the currently known pending tool calls for a given prompt (best-effort).
    public func pendingToolCalls(for promptID: UUID) -> [ToolCallInfo] {
        pendingToolCallsByPrompt[promptID] ?? []
    }

    /// Requests the current state of a specific prompt from the server.
    public func getPromptState(promptID: UUID) async throws {
        guard isValid else {
            throw GrokestratorError.sessionInvalidated
        }

        let request = GrokBuildRequest.getPromptState(
            instanceID: instanceID,
            promptID: promptID
        )
        try await sendRequest(.grokBuild(request))
    }

    /// Responds to a permission request for an in-flight prompt.
    public func respondToPermission(promptID: UUID, permissionId: String, chosenOption: String) async throws {
        guard isValid else { throw GrokestratorError.sessionInvalidated }
        try await sendRequest(.grokBuild(.respondToPermission(
            instanceID: instanceID, promptID: promptID,
            permissionId: permissionId, chosenOption: chosenOption
        )))
    }

    /// Fetches the latest capabilities for this remote instance. Sends a
    /// `getCapabilities` request and awaits the matching `capabilitiesUpdated`
    /// event. Falls back to the cached value on timeout so the UI never stalls.
    public func getCapabilities(timeout: Double = 5) async -> AgentCapabilities {
        guard isValid else { return cachedCapabilities }
        do { try await sendRequest(.grokBuild(.getCapabilities(instanceID: instanceID))) }
        catch { return cachedCapabilities }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.resolveCapabilitiesWithCache()
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<AgentCapabilities, Never>) in
            // A concurrent getCapabilities (e.g. poll + manual refresh) may have
            // set a continuation while we awaited the send — resolve it from
            // cache instead of leaking it, then take the slot.
            if let prev = self.capContinuation { self.capContinuation = nil; prev.resume(returning: self.cachedCapabilities) }
            self.capContinuation = cont
        }
        watchdog.cancel()
        return result
    }

    /// Fetches the latest token / context usage snapshot. Same pattern.
    public func getUsage(timeout: Double = 5) async -> SessionUsage {
        guard isValid else { return cachedUsage }
        do { try await sendRequest(.grokBuild(.getUsage(instanceID: instanceID))) }
        catch { return cachedUsage }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.resolveUsageWithCache()
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<SessionUsage, Never>) in
            if let prev = self.usageContinuation { self.usageContinuation = nil; prev.resume(returning: self.cachedUsage) }
            self.usageContinuation = cont
        }
        watchdog.cancel()
        return result
    }

    /// Fetches a media artifact's bytes from the host. `maxDimension != nil`
    /// requests a thumbnail/poster bounded to that pixel size; `nil` requests
    /// the full file. Returns `nil` on missing file, size-cap, or timeout — the
    /// UI shows a placeholder rather than hanging. Timeout is generous for full
    /// fetches (large videos over Tailscale) and short for thumbnails.
    /// Fetch a small in-memory thumbnail / poster (downscaled JPEG).
    public func fetchThumbnail(path: String, maxDimension: Int) async -> (data: Data, mimeType: String)? {
        guard isValid else { return nil }
        let id = UUID()
        transfers[id] = MediaTransfer(mode: .memory)
        do {
            try await sendRequest(.grokBuild(.fetchMedia(instanceID: instanceID, path: path, maxDimension: maxDimension, requestID: id)))
        } catch { transfers[id] = nil; return nil }
        armMediaWatchdog(id, inactivity: 20)
        return await withCheckedContinuation { dataConts[id] = $0 }
    }

    /// Fetch the full file, streamed chunk-by-chunk to a temp file on disk.
    /// Returns its URL (for AVPlayer / QuickLook) — the bytes never live wholly
    /// in memory client-side.
    public func fetchFullFile(path: String) async -> (url: URL, mimeType: String)? {
        guard isValid else { return nil }
        let id = UUID()
        let ext = (path as NSString).pathExtension
        transfers[id] = MediaTransfer(mode: .file(ext: ext.isEmpty ? "bin" : ext))
        do {
            try await sendRequest(.grokBuild(.fetchMedia(instanceID: instanceID, path: path, maxDimension: nil, requestID: id)))
        } catch { transfers[id] = nil; return nil }
        armMediaWatchdog(id, inactivity: 60)
        return await withCheckedContinuation { fileConts[id] = $0 }
    }

    private func armMediaWatchdog(_ requestID: UUID, inactivity: Double) {
        mediaWatchdogs[requestID]?.cancel()
        mediaWatchdogs[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(inactivity * 1_000_000_000))
            await self?.failTransfer(requestID, reason: "inactivity-timeout(\(inactivity)s)")
        }
    }

    /// Appends a chunk to its transfer (memory append or file write), opening
    /// the temp file lazily on the first chunk of a file transfer.
    private func appendChunk(_ chunk: MediaChunk, to id: UUID) {
        guard let t = transfers[id] else { return }
        if t.mime == nil { t.mime = chunk.mimeType }
        t.chunks += 1
        t.bytes += chunk.data.count
        switch t.mode {
        case .memory:
            t.data.append(chunk.data)
        case .file(let ext):
            if t.handle == nil {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gk-media-\(id.uuidString).\(ext)")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                t.url = url
                t.handle = try? FileHandle(forWritingTo: url)
                if t.handle == nil { failTransfer(id); return }
            }
            do { try t.handle?.write(contentsOf: chunk.data) }
            catch { failTransfer(id); return }
        }
    }

    private func finishTransfer(_ id: UUID) {
        mediaWatchdogs.removeValue(forKey: id)?.cancel()
        guard let t = transfers.removeValue(forKey: id) else { return }
        let mime = t.mime ?? "application/octet-stream"
        switch t.mode {
        case .memory:
            dataConts.removeValue(forKey: id)?.resume(returning: (data: t.data, mimeType: mime))
        case .file:
            try? t.handle?.close()
            fileConts.removeValue(forKey: id)?.resume(returning: t.url.map { (url: $0, mimeType: mime) })
        }
    }

    private func failTransfer(_ id: UUID, reason: String = "?") {
        let t = transfers.removeValue(forKey: id)
        _ = reason
        mediaWatchdogs.removeValue(forKey: id)?.cancel()
        if let t, case .file = t.mode {
            try? t.handle?.close()
            if let url = t.url { try? FileManager.default.removeItem(at: url) }
        }
        // Tell the host to stop streaming this (it doesn't know we gave up).
        let inst = instanceID
        Task { try? await self.sendRequest(.grokBuild(.cancelMedia(instanceID: inst, requestID: id))) }
        dataConts.removeValue(forKey: id)?.resume(returning: nil)
        fileConts.removeValue(forKey: id)?.resume(returning: nil)
    }

    private func resolveCapabilitiesWithCache() {
        if let cont = capContinuation {
            capContinuation = nil
            cont.resume(returning: cachedCapabilities)
        }
    }

    private func resolveUsageWithCache() {
        if let cont = usageContinuation {
            usageContinuation = nil
            cont.resume(returning: cachedUsage)
        }
    }

    // MARK: - Event Handling (called by the owning client)

    /// Called by the parent `GrokestratorClient` when a `GrokBuildEvent` arrives for this instance.
    public func handle(event: GrokBuildEvent) {
        guard isValid else { return }

        switch event {
        case .conversationUpdate(let instID, _, let update):
            guard instID == instanceID else { return }
            // Broadcast model: every inbound update fans to all UI subscribers,
            // regardless of which prompt (or which client) initiated it.
            broadcastEvent(.update(update))

        case .historySnapshot(let instID, let turns):
            guard instID == instanceID else { return }
            broadcastEvent(.snapshot(turns))

        case .pendingToolCallsChanged(let instID, let promptID, let calls):
            guard instID == instanceID else { return }
            pendingToolCallsByPrompt[promptID] = calls

        case .promptCompleted(let instID, _, _):
            guard instID == instanceID else { return }
            // Nothing to terminate in the broadcast model — subscriptions are
            // open-ended; the `.turnComplete` update already rode through.
            break

        case .instanceDied(let instID, _):
            guard instID == instanceID else { return }
            // A dead remote instance can no longer service this session at all.
            invalidate(reason: "Remote Grok Build instance died")

        case .capabilitiesUpdated(let instID, let caps):
            guard instID == instanceID else { return }
            cachedCapabilities = caps
            if let cont = capContinuation {
                capContinuation = nil
                cont.resume(returning: caps)
            }

        case .usageUpdated(let instID, let usage):
            guard instID == instanceID else { return }
            cachedUsage = usage
            if let cont = usageContinuation {
                usageContinuation = nil
                cont.resume(returning: usage)
            }

        case .mediaData(let instID, let requestID, let chunk):
            guard instID == instanceID else { return }
            // Ignore late chunks for a transfer we already finished/abandoned —
            // and tell the server to stop streaming it (saves wasted upload).
            guard transfers[requestID] != nil else {
                Task { try? await self.sendRequest(.grokBuild(.cancelMedia(instanceID: self.instanceID, requestID: requestID))) }
                return
            }
            guard let chunk else { failTransfer(requestID, reason: "nil-chunk-from-server"); return }
            appendChunk(chunk, to: requestID)
            if chunk.isFinal {
                finishTransfer(requestID)
            } else {
                armMediaWatchdog(requestID, inactivity: 60)   // progress → reset timer
            }

        case .error(let instID, _, let message):
            // Surface server-side failures (e.g. a prompt the Mac couldn't
            // start) to the conversation so the UI shows them and clears the
            // spinner. Without this, any backend error was a silent infinite
            // "waiting". `instID == nil` ⇒ unscoped error, still relevant.
            guard instID == nil || instID == instanceID else { return }
            broadcastEvent(.update(.error(message)))

        default:
            break
        }
    }

    /// Called when the underlying connection or instance becomes invalid.
    public func invalidate(reason: String = "Session invalidated") {
        guard isValid else { return }
        isValid = false
        invalidateAllPrompts(reason: reason)
    }

    // MARK: - Private

    private func invalidateAllPrompts(reason: String) {
        // Per-prompt streams are gone (broadcast model). Notify any UI
        // subscriber via an error update then close their stream.
        for (_, cont) in broadcastSubscribers {
            cont.yield(.update(.error(reason)))
            cont.finish()
        }
        broadcastSubscribers.removeAll()
        activePrompts.removeAll()
        pendingToolCallsByPrompt.removeAll()
        // Fail any in-flight media fetches so their awaiters don't hang.
        for (_, task) in mediaWatchdogs { task.cancel() }
        mediaWatchdogs.removeAll()
        for (_, t) in transfers where t.handle != nil {
            try? t.handle?.close()
            if let url = t.url { try? FileManager.default.removeItem(at: url) }
        }
        transfers.removeAll()
        for (_, cont) in dataConts { cont.resume(returning: nil) }
        for (_, cont) in fileConts { cont.resume(returning: nil) }
        dataConts.removeAll()
        fileConts.removeAll()
    }
}

