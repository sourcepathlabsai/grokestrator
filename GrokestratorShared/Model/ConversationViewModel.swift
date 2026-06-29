import Foundation
import Observation
import GrokestratorCore

/// One renderable line in the conversation transcript.
struct TranscriptEntry: Identifiable, Sendable {
    let id: UUID
    var kind: Kind

    enum Kind: Sendable {
        case userPrompt(String)
        /// A user prompt sitting in the queue, waiting for the current turn to
        /// finish before being sent. Renders with muted styling + a "queued"
        /// badge so the user knows their input was accepted. Replaced by a
        /// normal `.userPrompt` when the queued prompt fires.
        case queuedPrompt(String)
        /// Assistant answer text (may grow live as deltas stream in).
        case assistantMessage(String)
        /// Finalized assistant answer parsed into parts (text + inline images).
        case assistantContent([ContentPart])
        /// Assistant thinking text (may grow live as deltas stream in).
        case thought(String)
        /// A completed turn's thinking, coalesced into one collapsed,
        /// expandable "Thought process" group once the answer arrived. Replaces
        /// the loose live `.thought` rows so they don't clutter the finished
        /// turn but stay one tap away. Live-only — never persisted to history.
        case thoughtSummary(String)
        /// A completed turn's tool calls + progress/activity notes, coalesced
        /// into one collapsed, expandable group once the answer arrived — the
        /// same treatment as `.thoughtSummary`, so the finished turn shows just
        /// the answer instead of a stack of `🔧 tool(...)` / `↳ result` rows.
        /// Each element is a preformatted line. Live-only — never persisted.
        case toolActivitySummary([String])
        /// grok's live task checklist. There is at most ONE `.plan` entry in the
        /// transcript at a time: each plan re-broadcast replaces it in place
        /// (see `handle`'s `.planUpdated`), so the checklist updates rather than
        /// stacking up. Live-only — never persisted to history.
        case plan(AgentPlan)
        /// Any other update: tool calls, progress/activity notes, errors, turn divider, etc.
        case update(ConversationUpdate)
    }

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// One row in the virtualized transcript list: a transcript entry, or the
/// trailing live "thinking" indicator (kept in-list so it scrolls with the
/// content and stays reachable at the bottom). The indicator's identity is
/// stable across status changes so it updates in place rather than churning.
enum TranscriptListItem: Identifiable {
    case entry(TranscriptEntry)
    case indicator(String)

    enum ID: Hashable { case entry(UUID), indicator }

    var id: ID {
        switch self {
        case .entry(let entry): return .entry(entry.id)
        case .indicator: return .indicator
        }
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
    /// A short human label for what grok is doing *right now* — shown by the
    /// "thinking" indicator while `isStreaming` and rolled up into the sidebar's
    /// per-connection busy state. Updated as updates stream in ("Thinking…",
    /// "Responding…", "Using read_file…", a progress note's text) and reset when
    /// the turn ends. Live-only; never persisted.
    private(set) var activityStatus = "Thinking…"
    /// The permission request currently shown over the thread (the front of the
    /// queue). `nil` when there's nothing to answer. Claude Code issues tool calls in
    /// PARALLEL, so several permission requests can be in flight at once — they're
    /// queued and surfaced one at a time (a single overwriting value would strand all
    /// but the last, and the connection would hang since the watchdog won't age out
    /// while permissions are pending).
    private(set) var pendingPermission: PermissionRequestInfo?
    /// Permission requests awaiting an answer (front = the one on screen).
    private var permissionQueue: [PermissionRequestInfo] = []
    /// How many permission requests are waiting (for an "N of M" hint in the overlay).
    var pendingPermissionCount: Int { permissionQueue.count }
    /// A structured user question (`_x.ai/ask_user_question`) awaiting an answer,
    /// shown over the thread like `pendingPermission`. `nil` when nothing pending.
    private(set) var pendingUserQuestion: UserQuestionInfo?
    /// Confident quick-reply options for the last assistant question (set when a
    /// message finalizes; cleared on the next prompt). Empty ⇒ user types.
    private(set) var quickReplies: [String] = []
    /// Prompts waiting to fire after the current turn completes. Each entry is a
    /// pair of (prompt text, transcript entry id) so we can replace the queued-
    /// prompt row with a normal `.userPrompt` when it fires.
    private var promptQueue: [(text: String, entryID: UUID)] = []
    /// `true` when there are prompts waiting to fire (drives the "queued" badge).
    var hasQueuedPrompts: Bool { !promptQueue.isEmpty }
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

    /// The id of the assistant bubble currently being streamed into, *only* when
    /// it's a live message. The transcript renders this one as plain text —
    /// re-parsing Markdown of a rapidly-growing message on every refresh is the
    /// streaming hot path — and switches to full Markdown the moment it finalizes.
    var streamingMessageID: UUID? { streamingKind == .message ? streamingID : nil }

    // Streaming deltas are coalesced (see `enqueueDelta`) so a fast, long stream
    // refreshes the transcript at ~20 Hz instead of once per token.
    private var pendingDeltaText = ""
    private var pendingDeltaKind: StreamKind?
    private var deltaFlushScheduled = false
    private let flushIntervalNanos: UInt64 = 50_000_000   // ~20 Hz

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
        // IDEMPOTENT. The VM owns exactly one long-lived subscription for the
        // item's lifetime; the live transcript accumulates here independent of
        // which Connection is selected. Re-selecting a Connection re-fires the
        // view's `.task(id:)`, which calls this again — but if we're already
        // subscribed we must NOT tear down and wipe the stream. Doing so blanked
        // the transcript when switching Connections mid-turn (the fresh snapshot
        // has no in-progress answer and no thoughts), until the turn finished.
        guard subscriptionTask == nil else { return }

        // First/fresh subscription: reset local state, then replay `.snapshot`
        // (the broadcast's first event) and pump live `.update`s. `isStreaming`
        // resets so a stuck spinner can't survive; `sessionReady` resets so the
        // "Connecting…" banner reappears while capabilities come up.
        entries = []
        quickReplies = []
        permissionQueue = []
        pendingPermission = nil
        pendingUserQuestion = nil
        isStreaming = false
        activityStatus = "Thinking…"
        sessionReady = capabilities != nil
        endStreaming()
        discardPendingDelta()
        promptQueue.removeAll()
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
            // Stream ended (driver replaced / disconnected) — clear the handle so
            // a later call can establish a fresh subscription. Defensive: if the
            // stream died mid-turn without a terminal `.error`/`.turnComplete`
            // (e.g. a silent close), don't strand the spinner.
            if !Task.isCancelled, self.isStreaming {
                self.endStreaming()
                self.isStreaming = false
            }
            self.subscriptionTask = nil
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
        guard !trimmed.isEmpty else { return }

        // If a turn is in progress, queue the prompt instead of dropping it.
        // The queued prompt appears in the transcript immediately (muted) and
        // fires automatically when the current turn completes.
        if isStreaming {
            let entry = TranscriptEntry(kind: .queuedPrompt(trimmed))
            promptQueue.append((text: trimmed, entryID: entry.id))
            entries.append(entry)
            streamTick += 1
            return
        }

        firePrompt(trimmed)
    }

    /// Actually sends a prompt to the driver. Called by `send` (direct) and by
    /// `drainQueue` (after a turn completes). When `echoInTranscript` is false
    /// the optimistic `.userPrompt` row is skipped (the caller already placed it).
    private func firePrompt(_ trimmed: String, echoInTranscript: Bool = true) {
        quickReplies = []
        isStreaming = true
        activityStatus = "Thinking…"
        startUsagePolling()                 // live context meter during the turn
        if echoInTranscript {
            appendEntry(.userPrompt(trimmed))   // optimistic echo
        }
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
        discardPendingDelta()
        promptQueue.removeAll()   // snapshot wipes transient state
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
        permissionQueue.removeAll { $0.id == perm.id }
        pendingPermission = permissionQueue.first   // advance to the next concurrent request
        appendEntry(.update(.activityNote("\(option.isAllow ? "Approved" : "Declined"): \(perm.description)", kind: "permission", metadata: nil)))
        let driver = self.driver
        Task { await driver.respondToPermission(permissionId: perm.id, optionId: option.id) }
    }

    /// Answers a pending user question and dismisses the overlay, leaving a compact
    /// record in the thread. `answer` is either a chosen option's label or the
    /// user's free-text answer (the "Other" path). Mirrors `answerPermission`.
    func answerUserQuestion(questionIndex: Int, answer: String) {
        guard let q = pendingUserQuestion else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingUserQuestion = nil
        let prompt = q.questions.indices.contains(questionIndex) ? q.questions[questionIndex].prompt : ""
        appendEntry(.update(.activityNote("Answered\(prompt.isEmpty ? "" : " “\(prompt)”"): \(trimmed)", kind: "user_question", metadata: nil)))
        let driver = self.driver
        Task { await driver.respondToUserQuestion(questionId: q.id, questionIndex: questionIndex, answer: trimmed) }
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
        discardPendingDelta()
        clearPromptQueue()
        isStreaming = false
    }

    /// User pressed Stop. Clears the local spinner **immediately** so Stop is
    /// always responsive — including when the server is gone and the driver's
    /// cancel / `turnComplete` round-trip can never come back (the old code only
    /// asked the driver and waited for a broadcast that never arrived). Then it
    /// best-effort tells the driver to cancel so a *live* turn actually stops.
    /// Also clears the prompt queue — a manual Stop is an explicit "stop
    /// everything" signal.
    func cancelCurrent() {
        guard isStreaming else { return }
        endStreaming()
        discardPendingDelta()
        isStreaming = false
        clearPromptQueue()
        let driver = self.driver
        Task { await driver.cancel() }
    }

    /// Fires the next queued prompt (if any). Called after a turn completes
    /// naturally (`.turnComplete`). Replaces the queued-prompt transcript entry
    /// with a normal `.userPrompt` so it no longer looks "pending".
    private func drainQueue() {
        guard let next = promptQueue.first else { return }
        promptQueue.removeFirst()
        // Replace the `.queuedPrompt` row with a normal `.userPrompt`.
        if let idx = entries.firstIndex(where: { $0.id == next.entryID }) {
            entries[idx].kind = .userPrompt(next.text)
        }
        streamTick += 1
        firePrompt(next.text, echoInTranscript: false)
    }

    /// Removes all queued prompts and their transcript entries (used on Stop,
    /// cancel, and snapshot replay).
    private func clearPromptQueue() {
        let ids = Set(promptQueue.map(\.entryID))
        entries.removeAll { ids.contains($0.id) }
        promptQueue.removeAll()
        streamTick += 1
    }

    // MARK: - Update handling

    private func handle(_ update: ConversationUpdate) {
        // Streaming deltas are coalesced and flushed on a timer (~20 Hz) so a
        // fast, long stream can't drive a full transcript re-parse + relayout per
        // token — that was the main-thread beach-ball on long output. Every other
        // (structural / terminal) update flushes the buffer first, so transcript
        // order stays exact, then applies immediately.
        switch update {
        case .messageDelta(let t):
            isStreaming = true
            activityStatus = "Responding…"
            enqueueDelta(t, kind: .message)
            return
        case .thoughtDelta(let t):
            isStreaming = true
            activityStatus = "Thinking…"
            enqueueDelta(t, kind: .thought)
            return
        default:
            flushPendingDelta()
        }

        switch update {
        case .userPrompt(let text):
            // Either we initiated this prompt (and the subscription is echoing
            // back our optimistic local append from `send`) or another client
            // did. Dedup via tail-match: if the very last entry is already a
            // `.userPrompt` with the same text, drop the echo. Otherwise — a
            // turn started by another connected client — append it.
            endStreaming()
            // A turn has begun — reflect "busy" on *every* subscriber, including
            // a host watching a turn another client drove (which never goes
            // through `send`). `turnComplete`/`.error` clear it.
            isStreaming = true
            activityStatus = "Thinking…"
            if case .userPrompt(let last) = entries.last?.kind, last == text { break }
            appendEntry(.userPrompt(text))
        case .message(let full, _):
            finalize(full, kind: .message)
        case .thought(let full, _):
            finalize(full, kind: .thought)
        case .permissionRequested(let info):
            // Surface over the thread (overlay). Enqueue (deduped) so concurrent
            // requests — Claude's parallel tool use — are answered one at a time
            // instead of clobbering each other.
            endStreaming()
            if !permissionQueue.contains(where: { $0.id == info.id }) { permissionQueue.append(info) }
            pendingPermission = permissionQueue.first
        case .userQuestionRequested(let info):
            // Surface over the thread (overlay), like a permission request.
            endStreaming()
            pendingUserQuestion = info
        case .interactionResolved(let id):
            // Answered on some device — drop it from the queue and advance to the next
            // (others in flight are preserved).
            permissionQueue.removeAll { $0.id == id }
            pendingPermission = permissionQueue.first
            if pendingUserQuestion?.id == id { pendingUserQuestion = nil }
        case .planUpdated(let plan):
            // grok re-broadcasts the ENTIRE plan on every status change. Keep a
            // single live checklist that updates IN PLACE: replace the existing
            // `.plan` entry's kind if present, otherwise append a new one. This
            // is the same single-live-widget spirit as `collapseThoughts`.
            isStreaming = true
            activityStatus = "Planning…"
            if let idx = entries.firstIndex(where: {
                if case .plan = $0.kind { return true } else { return false }
            }) {
                entries[idx].kind = .plan(plan)
            } else {
                entries.append(TranscriptEntry(kind: .plan(plan)))
            }
            streamTick += 1
        case .error:
            // A failure ends the turn — clear the spinner (only `.turnComplete`
            // did before, so an error left "waiting" spinning forever), tuck away
            // any live thinking, and show the message inline.
            endStreaming()
            isStreaming = false
            activityStatus = "Thinking…"
            collapseWork()
            appendEntry(.update(update))
            // Fire the next queued prompt despite the error — the user
            // explicitly typed it and wants it processed.
            drainQueue()
        case .turnComplete:
            endStreaming()
            isStreaming = false
            activityStatus = "Thinking…"
            // The final answer has landed — collapse the turn's live thinking
            // and tool calls into expandable groups. (Belt-and-braces: we also
            // collapse when the answer message itself finalizes, so a turn that
            // never sends `.turnComplete` doesn't strand them.)
            collapseWork()
            appendEntry(.update(update))
            refreshUsage()
            // Fire the next queued prompt (if any). Must come after isStreaming
            // is cleared and the turn divider is appended so the transcript
            // reads naturally.
            drainQueue()
        default:
            endStreaming()
            // Tool calls / progress / activity notes mean grok is actively
            // working — reflect that as busy and surface what it's doing.
            if let label = activityLabel(for: update) {
                isStreaming = true
                activityStatus = label
            }
            appendEntry(.update(update))
        }
    }

    /// A short "what's happening now" label for the busy indicator, derived from
    /// a work update (tool call, progress/activity note). `nil` for updates that
    /// aren't agent work (session status, user-decision records, etc.) so they
    /// don't flip the connection to "busy".
    private func activityLabel(for update: ConversationUpdate) -> String? {
        switch update {
        case .toolCallRequested(let info):
            return "Using \(info.toolName)…"
        case .progressNote(let text, let phase, _):
            let t = phase.map { "\($0): \(text)" } ?? text
            return t.isEmpty ? nil : t
        case .activityNote(let text, let kind, _):
            if kind == "permission" || kind == "user_question" { return nil }
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    // MARK: - Delta coalescing (streaming throttle)

    /// Buffers a streaming delta and schedules a flush. Coalescing many tokens
    /// into one transcript mutation per ~`flushIntervalNanos` is what keeps a
    /// fast, long stream from wedging the main thread (a re-parse + full
    /// re-host/relayout per token). A kind switch (thought→message) flushes first
    /// so the two never merge into one bubble.
    private func enqueueDelta(_ text: String, kind: StreamKind) {
        if let k = pendingDeltaKind, k != kind { flushPendingDelta() }
        pendingDeltaKind = kind
        pendingDeltaText += text
        guard !deltaFlushScheduled else { return }
        deltaFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.flushIntervalNanos ?? 50_000_000)
            self?.flushPendingDelta()
        }
    }

    /// Applies buffered streaming text to the transcript in a single mutation.
    /// Called by the flush timer and synchronously before any structural update,
    /// so order is exact.
    private func flushPendingDelta() {
        deltaFlushScheduled = false
        guard let kind = pendingDeltaKind, !pendingDeltaText.isEmpty else {
            pendingDeltaKind = nil
            return
        }
        let text = pendingDeltaText
        pendingDeltaText = ""
        pendingDeltaKind = nil
        appendDelta(text, kind: kind)
    }

    /// Drops any buffered delta without applying it — for snapshot replay,
    /// re-subscribe, and cancel, where the buffered text belongs to a context
    /// that no longer exists. (A pending flush task then finds an empty buffer
    /// and no-ops.)
    private func discardPendingDelta() {
        pendingDeltaText = ""
        pendingDeltaKind = nil
        deltaFlushScheduled = false
    }

    private func appendDelta(_ text: String, kind: StreamKind) {
        // The answer is starting to arrive — tuck the turn's thinking and tool
        // calls into collapsed groups right away (idempotent once collapsed).
        if kind == .message { collapseWork() }
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
        // A finalized answer collapses the turn's thinking + tool calls even if
        // no `.message` deltas (and no `.turnComplete`) ever arrived — the case
        // that left the old erase-on-turnComplete path stranding live thoughts.
        if kind == .message { collapseWork() }
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

    /// Tuck the just-finished turn's transient work — live thinking and the
    /// `🔧 tool(...)` / progress rows — into collapsed, expandable groups so the
    /// finished turn reads as just its answer.
    private func collapseWork() {
        collapseThoughts()
        collapseToolActivity()
    }

    /// One preformatted line for a collapsible "work" update (tool call, tool
    /// result, progress/activity note), or `nil` if the update should stay
    /// inline (answers, errors, explicit user permission/question decisions, etc.).
    private func toolActivityLine(_ update: ConversationUpdate) -> String? {
        switch update {
        case .toolCallRequested(let info):
            let args = (info.arguments ?? [:]).map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
            return "🔧 \(info.toolName)(\(args))"
        case .toolResultRecorded(let id, let isError):
            return "↳ tool \(id) \(isError ? "failed" : "ok")"
        case .progressNote(let text, let phase, _):
            return "\(phase.map { "[\($0)] " } ?? "")\(text)"
        case .activityNote(let text, let kind, _):
            // Collapse all agent activity chatter (tool updates, fs ops, progress,
            // etc.). Only explicit user decision records (appended after the user
            // answers a permission or question) stay visible inline.
            let isUserDecision = (kind == "permission" || kind == "user_question")
            return isUserDecision ? nil : text
        default:
            return nil
        }
    }

    /// Coalesce the current turn's loose tool-call / progress rows into one
    /// collapsed `.toolActivitySummary`, placed where the first one was. Same
    /// incremental, idempotent contract as `collapseThoughts`: a prior turn's
    /// summary is a different kind, so only this turn's loose rows are folded.
    private func collapseToolActivity() {
        func isWork(_ kind: TranscriptEntry.Kind) -> Bool {
            if case .update(let u) = kind { return toolActivityLine(u) != nil }
            return false
        }
        // Scope to the current (last) turn only: work items before the most recent
        // userPrompt belong to history and must not be touched.
        let currentTurnStart = entries.lastIndex(where: { if case .userPrompt = $0.kind { return true } else { return false } }) ?? -1
        let workIndices = entries.indices.filter { $0 > currentTurnStart && isWork(entries[$0].kind) }
        guard let firstIdx = workIndices.first else { return }
        let lines: [String] = workIndices.compactMap { idx in
            if case .update(let u) = entries[idx].kind { return toolActivityLine(u) }
            return nil
        }
        // Remove from the end so earlier indices stay valid
        for idx in workIndices.reversed() { entries.remove(at: idx) }
        guard !lines.isEmpty else { streamTick += 1; return }
        let insertAt = min(firstIdx, entries.count)
        entries.insert(TranscriptEntry(kind: .toolActivitySummary(lines)), at: insertAt)
        streamTick += 1
    }

    /// Coalesce the current turn's loose live `.thought` rows into a single
    /// collapsed `.thoughtSummary` placed where the first thought was (i.e. just
    /// above the answer). Idempotent — once collapsed there are no loose thoughts
    /// left, so repeat calls do nothing. Only this turn's thoughts are affected;
    /// a prior turn's already-collapsed summary is a different kind and untouched.
    private func collapseThoughts() {
        let currentTurnStart = entries.lastIndex(where: { if case .userPrompt = $0.kind { return true } else { return false } }) ?? -1
        let thoughtIndices = entries.indices.filter { idx in
            idx > currentTurnStart && { if case .thought = entries[idx].kind { return true } else { return false } }()
        }
        guard let firstIdx = thoughtIndices.first else { return }
        let texts: [String] = thoughtIndices.compactMap { idx in
            if case .thought(let t) = entries[idx].kind { return t }
            return nil as String?
        }
        let combined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for idx in thoughtIndices.reversed() { entries.remove(at: idx) }
        guard !combined.isEmpty else { streamTick += 1; return }
        // If this thought entry was the one being streamed into, clear the marker
        // so a trailing thoughtDelta doesn't try to grow a now-removed row.
        if streamingKind == .thought { endStreaming() }
        let insertAt = min(firstIdx, entries.count)
        entries.insert(TranscriptEntry(kind: .thoughtSummary(combined)), at: insertAt)
        streamTick += 1
    }
}
