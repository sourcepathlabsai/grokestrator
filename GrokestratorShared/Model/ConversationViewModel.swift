import Foundation
import Observation
import GrokestratorCore

/// One renderable line in the conversation transcript.
struct TranscriptEntry: Identifiable, Sendable {
    let id: UUID
    var kind: Kind

    enum Kind: Sendable {
        case userPrompt(String)
        /// Assistant answer text (may grow live as deltas stream in).
        case assistantMessage(String)
        /// Finalized assistant answer parsed into parts (text + inline images).
        case assistantContent([ContentPart])
        /// Assistant thinking text (may grow live as deltas stream in).
        case thought(String)
        /// Any other update: tool calls, progress/activity notes, errors, turn divider, etc.
        case update(ConversationUpdate)
    }

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// MainActor-facing state for a single conversation.
///
/// Bridges the actor-based `AsyncStream<ConversationUpdate>` (black box / mock)
/// to SwiftUI. Streamed `messageDelta` / `thoughtDelta` updates grow the current
/// bubble in place (live typing); the coalesced `message` / `thought` finalize it.
@MainActor
@Observable
final class ConversationViewModel {
    private(set) var entries: [TranscriptEntry] = []
    private(set) var isStreaming = false
    /// A permission request awaiting the user's decision (shown over the thread,
    /// not inline). `nil` when there is nothing to answer.
    private(set) var pendingPermission: PermissionRequestInfo?
    /// Confident quick-reply options for the last assistant question (set when a
    /// message finalizes; cleared on the next prompt). Empty ⇒ user types.
    private(set) var quickReplies: [String] = []
    /// Bumped on every transcript mutation so views can keep scrolled to the bottom
    /// even while a bubble grows in place (entry count doesn't change then).
    private(set) var streamTick = 0
    /// Instance capabilities (model, MCP servers, slash commands) for the Instance
    /// Inspector and the composer slash-command popup. Loaded lazily on first view.
    private(set) var capabilities: AgentCapabilities?

    /// Slash commands advertised by the instance (for the composer popup).
    var slashCommands: [SlashCommand] { capabilities?.commands ?? [] }
    /// Token / context usage for the Instance Inspector. Refreshed after each turn.
    private(set) var usage: SessionUsage?
    /// `true` once `loadCapabilities` has succeeded at least once — i.e. grok
    /// answered `initialize` and we have its model/MCP/commands. Drives the
    /// "Connecting…" banner: shown when we're trying to load but haven't yet.
    /// Cleared on subscribe (a fresh Connection-switch shows the banner again
    /// while the new instance's capabilities come up).
    private(set) var sessionReady: Bool = false
    /// The composer's draft text — kept on the VM so other surfaces (notably the
    /// Instance Inspector's slash-command list, which inserts on double-click) can
    /// write into it without going through the view.
    var draft: String = ""
    /// Bumped to ask the composer to take keyboard focus (e.g. right after an
    /// inserted slash command, so the user can immediately type the argument).
    private(set) var focusToken: Int = 0
    func requestComposerFocus() { focusToken += 1 }

    private let driver: ConversationDriver

    /// Loads + caches media artifacts (images/video/files) for this
    /// conversation. Injected into the transcript via `\.mediaLoader` so media
    /// part views can fetch `.serverFile` artifacts from the host on demand.
    let mediaLoader: MediaLoader

    // Tracks the bubble currently being streamed into.
    private enum StreamKind { case message, thought }
    private var streamingID: UUID?
    private var streamingKind: StreamKind?

    init(driver: ConversationDriver) {
        self.driver = driver
        self.mediaLoader = MediaLoader(
            thumbnail: { [driver] path, dim in await driver.fetchMediaThumbnail(path: path, maxDimension: dim) },
            file: { [driver] path in await driver.fetchMediaFile(path: path) },
            url: { [driver] path in driver.mediaURL(forHostPath: path) }
        )
    }

    /// Loads instance capabilities. **Patient**: polls forever until grok's
    /// `initialize` returns or the view goes away (the parent Task's cancellation
    /// breaks the loop). Earlier versions capped at 6s, which lost the race on
    /// Connections with several MCP servers — `initialize` legitimately takes
    /// 10–30 s while `npx`/`uvx` spawn each server. The UI surfaces a
    /// "Connecting…" banner via `sessionReady == false` so a long wait reads
    /// as progress rather than a deadlocked spinner.
    /// `true` while we're still polling for late-registering slash commands —
    /// grok's MCP servers load asynchronously and stream their commands in via
    /// `available_commands_update` over several seconds. Drives a "loading
    /// commands…" hint in the slash popup.
    private(set) var commandsSettling = false

    func loadCapabilities(force: Bool = false) {
        guard force || capabilities == nil else { return }
        let driver = self.driver
        Task { [weak self] in
            // Poll fast until grok answers `initialize` with *something*, then
            // keep watching at a slower cadence: MCP servers finish loading after
            // the handshake and push more commands via `available_commands_update`.
            // Stop once the command count holds steady (MCP load settled).
            var lastCount = -1, stablePolls = 0, polls = 0
            while !Task.isCancelled {
                let caps = await driver.capabilities()
                guard let self else { return }
                if let caps, caps != .empty {
                    if caps != self.capabilities { self.capabilities = caps }
                    self.sessionReady = true
                    if caps.commands.count == lastCount { stablePolls += 1 }
                    else { stablePolls = 0; lastCount = caps.commands.count }
                    // Settle once the command count holds steady, or give up
                    // watching after a bounded window — we don't want a perpetual
                    // poll loop competing with other traffic (e.g. media) on the
                    // connection. `/`-open does a one-shot refresh anyway.
                    polls += 1
                    self.commandsSettling = stablePolls < 4 && polls < 15
                    if !self.commandsSettling { return }
                }
                try? await Task.sleep(nanoseconds: self.sessionReady ? 2_000_000_000 : 500_000_000)
            }
        }
    }

    /// Force an immediate capabilities re-read (e.g. when the user opens the `/`
    /// popup) so the freshest command list — including MCP commands that have
    /// registered since — shows right away.
    func refreshCapabilities() {
        let driver = self.driver
        Task { [weak self] in
            let caps = await driver.capabilities()
            if let caps, caps != .empty { self?.capabilities = caps }
        }
    }

    /// Refreshes token / context usage (for the inspector). Called on view appear
    /// and after each turn completes.
    func refreshUsage() {
        let driver = self.driver
        Task { [weak self] in
            if let u = await driver.usage() { self?.usage = u }
        }
    }

    /// While a turn is streaming, poll usage so the inspector's context meter
    /// ticks up live (grok reports a running `totalTokens` mid-turn) instead of
    /// only jumping at turn end. Self-terminates when streaming stops.
    private var usagePollTask: Task<Void, Never>?
    private func startUsagePolling() {
        usagePollTask?.cancel()
        let driver = self.driver
        usagePollTask = Task { [weak self] in
            while !Task.isCancelled, self?.isStreaming == true {
                if let u = await driver.usage() { self?.usage = u }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Opens (or re-opens) the Connection's broadcast subscription and pumps
    /// `.snapshot` + `.update` events into `entries`. Call once per view
    /// appear, with the matching `id:` so a Connection switch re-subscribes
    /// cleanly. Cancellation of the awaiting Task ends the subscription.
    /// Owns the live broadcast subscription as a self-managed task so it can
    /// outlive any single view. The host keeps this running for its local
    /// Connections even when their conversation isn't on-screen — otherwise a
    /// turn driven from a *remote* device wouldn't appear on the host until it
    /// happened to open that conversation.
    private var subscriptionTask: Task<Void, Never>?

    func startSubscription() {
        // A fresh subscription always begins with `.snapshot` — wipe local
        // state so we don't accumulate from a previous selection. Crucially
        // reset `isStreaming` too: a stuck spinner from a previous (possibly
        // raced) send shouldn't survive into a re-subscribe. `sessionReady`
        // resets so the "Connecting…" banner reappears while the new
        // Connection's capabilities come up.
        subscriptionTask?.cancel()
        entries = []
        quickReplies = []
        pendingPermission = nil
        isStreaming = false
        sessionReady = capabilities != nil
        endStreaming()
        streamTick += 1

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.driver.subscribe()
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .snapshot(let turns): self.replay(turns: turns)
                case .update(let update): self.handle(update)
                }
            }
        }
    }

    /// Fires a prompt at the driver. **Fire-and-forget** in the broadcast model:
    /// every response update flows back via the active subscription, not from
    /// this call's return.
    ///
    /// The user's prompt is appended **optimistically** before the network /
    /// actor round-trip so it shows up in the transcript *immediately*. The
    /// broadcast echo (the `.userPrompt` event we'll receive over the
    /// subscription) is then deduped in `handle(_:)` via tail-match. Result:
    /// the UI never looks frozen, even when grok itself is slow to come up.
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        quickReplies = []
        isStreaming = true
        startUsagePolling()                 // live context meter during the turn
        appendEntry(.userPrompt(trimmed))   // optimistic echo
        let driver = self.driver
        Task { [weak self] in
            do {
                try await driver.send(trimmed)
            } catch {
                self?.handle(.error(error.localizedDescription))
                self?.endStreaming()
                self?.isStreaming = false
            }
        }
    }

    /// Replay a history snapshot into transcript entries. Mirrors the live
    /// `finalize` path: each assistant message is parsed with `ContentParser`
    /// so inline image/audio/video/file references in historical responses
    /// render the same way they do live. Thoughts (stored with a `"[thought] "`
    /// content prefix per `AgentConversationHistory.appendEvent`) are restored
    /// as `.thought` entries so the UI styling matches.
    private func replay(turns: [AgentTurn]) {
        var rebuilt: [TranscriptEntry] = []
        for turn in turns {
            rebuilt.append(TranscriptEntry(kind: .userPrompt(turn.userPrompt)))
            for msg in turn.messages {
                switch msg.role {
                case .assistant, .system:
                    if msg.content.hasPrefix("[thought] ") {
                        let stripped = String(msg.content.dropFirst("[thought] ".count))
                        rebuilt.append(TranscriptEntry(kind: .thought(stripped)))
                    } else {
                        rebuilt.append(TranscriptEntry(kind: kind(forMessageContent: msg.content)))
                    }
                case .tool:
                    rebuilt.append(TranscriptEntry(kind: .update(
                        .activityNote("tool: \(msg.content)", kind: "tool", metadata: nil)
                    )))
                case .user:
                    // Already covered by the turn's userPrompt above; skip dup.
                    break
                }
            }
        }
        entries = rebuilt
        // A snapshot is the server's authoritative view — nothing is mid-stream
        // by definition. Reset transient streaming flags so spinners and quick
        // replies don't carry over from a previous, possibly raced, state.
        isStreaming = false
        endStreaming()
        streamTick += 1
        refreshUsage()
    }

    /// Appends a system-level note (e.g. launch status or errors) to the transcript.
    func appendSystem(_ text: String, isError: Bool = false) {
        endStreaming()
        appendEntry(.update(isError ? .error(text) : .sessionStatus(text)))
    }

    /// Answers the pending permission request and dismisses the overlay,
    /// leaving a compact record in the thread.
    func answerPermission(_ option: PermissionOption) {
        guard let perm = pendingPermission else { return }
        pendingPermission = nil
        appendEntry(.update(.activityNote("\(option.isAllow ? "Approved" : "Declined"): \(perm.description)", kind: "permission", metadata: nil)))
        let driver = self.driver
        Task { await driver.respondToPermission(permissionId: perm.id, optionId: option.id) }
    }

    /// Clears the Connection's chat history. Fire-and-forget: the driver wipes
    /// the stored transcript and the cleared state arrives back as an empty
    /// `.snapshot` over the active subscription (`replay([])`), so this view and
    /// every other connected device reset together. We don't mutate `entries`
    /// directly here — letting the snapshot drive it keeps all clients in sync.
    func clearHistory() {
        let driver = self.driver
        Task { await driver.clearHistory() }
    }

    /// Soft-cancel: clears local streaming state. The broadcast subscription is
    /// owned by `subscriptionTask` (re-armed on each `startSubscription`), so it
    /// is left untouched here.
    func cancel() {
        endStreaming()
        isStreaming = false
    }

    /// User pressed Stop. Asks the driver to cancel the in-flight turn —
    /// which broadcasts `turnComplete` back through the subscription, so every
    /// connected device (this Mac + any remote GKSCs viewing the same
    /// Connection) sees the spinner clear together.
    func cancelCurrent() {
        guard isStreaming else { return }
        let driver = self.driver
        Task { await driver.cancel() }
    }

    // MARK: - Update handling

    private func handle(_ update: ConversationUpdate) {
        switch update {
        case .userPrompt(let text):
            // Either we initiated this prompt (and the subscription is echoing
            // back our optimistic local append from `send`) or another client
            // did. Dedup via tail-match: if the very last entry is already a
            // `.userPrompt` with the same text, drop the echo. Otherwise — a
            // turn started by another connected client — append it.
            endStreaming()
            if case .userPrompt(let last) = entries.last?.kind, last == text { break }
            appendEntry(.userPrompt(text))
        case .messageDelta(let t):
            appendDelta(t, kind: .message)
        case .thoughtDelta(let t):
            appendDelta(t, kind: .thought)
        case .message(let full, _):
            finalize(full, kind: .message)
        case .thought(let full, _):
            finalize(full, kind: .thought)
        case .permissionRequested(let info):
            // Surface over the thread (overlay), not as an inline row.
            endStreaming()
            pendingPermission = info
        case .error:
            // A failure ends the turn — clear the spinner (only `.turnComplete`
            // did before, so an error left "waiting" spinning forever) and show
            // the message inline.
            endStreaming()
            isStreaming = false
            appendEntry(.update(update))
        case .turnComplete:
            endStreaming()
            isStreaming = false
            // Ephemeral thoughts: the final answer has landed, so erase the
            // turn's thinking — it was shown live while the agent worked, but
            // it's noise once the answer is here. (History never persisted it,
            // so a reload is already clean; this clears the live transcript.)
            entries.removeAll { if case .thought = $0.kind { return true } else { return false } }
            appendEntry(.update(update))
            refreshUsage()
        default:
            endStreaming()
            appendEntry(.update(update))
        }
    }

    private func appendDelta(_ text: String, kind: StreamKind) {
        if streamingKind == kind, let id = streamingID, let idx = entries.firstIndex(where: { $0.id == id }) {
            switch entries[idx].kind {
            case .assistantMessage(let s): entries[idx].kind = .assistantMessage(s + text)
            case .thought(let s): entries[idx].kind = .thought(s + text)
            default: break
            }
            streamTick += 1
        } else {
            endStreaming()
            let entry = TranscriptEntry(kind: kind == .message ? .assistantMessage(text) : .thought(text))
            entries.append(entry)
            streamingID = entry.id
            streamingKind = kind
            streamTick += 1
        }
    }

    /// A coalesced full message/thought arrived — finalize the streaming bubble
    /// (replacing with authoritative text) or add a finalized entry if none.
    private func finalize(_ full: String, kind: StreamKind) {
        let finalKind = finalizedKind(full, kind: kind)
        if streamingKind == kind, let id = streamingID, let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].kind = finalKind
        } else {
            endStreaming()
            entries.append(TranscriptEntry(kind: finalKind))
        }
        endStreaming()
        streamTick += 1
    }

    /// A finalized assistant message is analyzed for quick-reply options (which
    /// also strips any `[[CHOICES]]` block from the displayed text) and parsed for
    /// inline content (images). Thoughts pass through unchanged.
    private func finalizedKind(_ full: String, kind: StreamKind) -> TranscriptEntry.Kind {
        guard kind == .message else { return .thought(full) }
        let (display, options) = QuickReplyDetector.analyze(full)
        quickReplies = options
        return self.kind(forMessageContent: display)
    }

    /// Parses an assistant-message string into the right transcript-entry kind:
    /// `.assistantContent(parts)` when `ContentParser` finds inline media,
    /// `.assistantMessage(text)` otherwise. Shared by the live finalize path
    /// and history replay, so a re-opened transcript renders identically to
    /// the original live stream.
    private func kind(forMessageContent text: String) -> TranscriptEntry.Kind {
        let parts = ContentParser.parse(text, remote: driver.resolvesMediaRemotely)
        let hasMedia = parts.contains { if case .text = $0 { return false } else { return true } }
        return hasMedia ? .assistantContent(parts) : .assistantMessage(text)
    }

    private func appendEntry(_ kind: TranscriptEntry.Kind) {
        entries.append(TranscriptEntry(kind: kind))
        streamTick += 1
    }

    private func endStreaming() {
        streamingID = nil
        streamingKind = nil
    }
}
