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
    /// A structured user question (`_x.ai/ask_user_question`) awaiting an answer,
    /// shown over the thread like `pendingPermission`. `nil` when nothing pending.
    private(set) var pendingUserQuestion: UserQuestionInfo?
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
        pendingPermission = nil
        pendingUserQuestion = nil
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
            // Stream ended (driver replaced / disconnected) — clear the handle so
            // a later call can establish a fresh subscription.
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
        case .userQuestionRequested(let info):
            // Surface over the thread (overlay), like a permission request.
            endStreaming()
            pendingUserQuestion = info
        case .planUpdated(let plan):
            // grok re-broadcasts the ENTIRE plan on every status change. Keep a
            // single live checklist that updates IN PLACE: replace the existing
            // `.plan` entry's kind if present, otherwise append a new one. This
            // is the same single-live-widget spirit as `collapseThoughts`.
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
            collapseWork()
            appendEntry(.update(update))
        case .turnComplete:
            endStreaming()
            isStreaming = false
            // The final answer has landed — collapse the turn's live thinking
            // and tool calls into expandable groups. (Belt-and-braces: we also
            // collapse when the answer message itself finalizes, so a turn that
            // never sends `.turnComplete` doesn't strand them.)
            collapseWork()
            appendEntry(.update(update))
            refreshUsage()
        default:
            endStreaming()
            appendEntry(.update(update))
        }
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
    /// result, progress/tool-activity note), or `nil` if the update should stay
    /// inline (answers, errors, permission/question records, status, etc.).
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
            // Only tool activity collapses; permission/user_question records,
            // which mark real user decisions, stay visible inline.
            return kind == "tool" ? text : nil
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
        guard let firstIdx = entries.firstIndex(where: { isWork($0.kind) }) else { return }
        let lines: [String] = entries.compactMap {
            if case .update(let u) = $0.kind { return toolActivityLine(u) }
            return nil
        }
        entries.removeAll { isWork($0.kind) }
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
        guard let firstIdx = entries.firstIndex(where: {
            if case .thought = $0.kind { return true } else { return false }
        }) else { return }
        let texts: [String] = entries.compactMap {
            if case .thought(let t) = $0.kind { return t } else { return nil }
        }
        let combined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { if case .thought = $0.kind { return true } else { return false } }
        guard !combined.isEmpty else { streamTick += 1; return }
        // If this thought entry was the one being streamed into, clear the marker
        // so a trailing thoughtDelta doesn't try to grow a now-removed row.
        if streamingKind == .thought { endStreaming() }
        let insertAt = min(firstIdx, entries.count)
        entries.insert(TranscriptEntry(kind: .thoughtSummary(combined)), at: insertAt)
        streamTick += 1
    }
}
