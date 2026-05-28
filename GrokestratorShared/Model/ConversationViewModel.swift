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
    /// The composer's draft text — kept on the VM so other surfaces (notably the
    /// Instance Inspector's slash-command list, which inserts on double-click) can
    /// write into it without going through the view.
    var draft: String = ""
    /// Bumped to ask the composer to take keyboard focus (e.g. right after an
    /// inserted slash command, so the user can immediately type the argument).
    private(set) var focusToken: Int = 0
    func requestComposerFocus() { focusToken += 1 }

    private let driver: ConversationDriver

    // Tracks the bubble currently being streamed into.
    private enum StreamKind { case message, thought }
    private var streamingID: UUID?
    private var streamingKind: StreamKind?

    init(driver: ConversationDriver) {
        self.driver = driver
    }

    /// Loads instance capabilities once (idempotent). Race-tolerant: polls the
    /// driver a few times so a freshly-created Connection (whose grok process
    /// is still starting up) eventually surfaces its model / MCP / commands
    /// instead of leaving the inspector empty.
    func loadCapabilities(force: Bool = false) {
        guard force || capabilities == nil else { return }
        let driver = self.driver
        Task { [weak self] in
            // ~6s @ 300ms — long enough for grok's initialize handshake under
            // the worst observed launch latency, short enough that the user
            // doesn't sit waiting if the instance is truly broken.
            for _ in 0..<20 {
                if let caps = await driver.capabilities(), caps != .empty {
                    self?.capabilities = caps
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
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

    /// Opens (or re-opens) the Connection's broadcast subscription and pumps
    /// `.snapshot` + `.update` events into `entries`. Call once per view
    /// appear, with the matching `id:` so a Connection switch re-subscribes
    /// cleanly. Cancellation of the awaiting Task ends the subscription.
    func startSubscription() async {
        // A fresh subscription always begins with `.snapshot` — wipe local
        // state so we don't accumulate from a previous selection. Crucially
        // reset `isStreaming` too: a stuck spinner from a previous (possibly
        // raced) send shouldn't survive into a re-subscribe.
        entries = []
        quickReplies = []
        pendingPermission = nil
        isStreaming = false
        endStreaming()
        streamTick += 1

        let stream = await driver.subscribe()
        for await event in stream {
            switch event {
            case .snapshot(let turns): replay(turns: turns)
            case .update(let update): handle(update)
            }
        }
    }

    /// Fires a prompt at the driver. **Fire-and-forget** in the broadcast model:
    /// the user prompt + every response update flows back via the active
    /// subscription, not from this call's return.
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        quickReplies = []
        isStreaming = true
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

    /// Replay a history snapshot into transcript entries — converts
    /// `[AgentTurn]` to user-prompt + assistant-message entries. Used both when
    /// joining a Connection for the first time and when the Connection switches.
    private func replay(turns: [AgentTurn]) {
        var rebuilt: [TranscriptEntry] = []
        for turn in turns {
            rebuilt.append(TranscriptEntry(kind: .userPrompt(turn.userPrompt)))
            for msg in turn.messages {
                switch msg.role {
                case .assistant, .system:
                    rebuilt.append(TranscriptEntry(kind: .assistantMessage(msg.content)))
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

    /// Soft-cancel: clears local streaming state. The subscription itself is
    /// owned by the view's `.task(id:)` and is auto-cancelled when the view
    /// goes away, dropping the server-side broadcaster registration cleanly.
    func cancel() {
        endStreaming()
        isStreaming = false
    }

    // MARK: - Update handling

    private func handle(_ update: ConversationUpdate) {
        switch update {
        case .userPrompt(let text):
            // Either we initiated this prompt (and the subscription is echoing
            // it back), or another client did. Either way, record it once.
            endStreaming()
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
        case .turnComplete:
            endStreaming()
            isStreaming = false
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
        let parts = ContentParser.parse(display)
        let hasMedia = parts.contains { if case .text = $0 { return false } else { return true } }
        return hasMedia ? .assistantContent(parts) : .assistantMessage(display)
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
