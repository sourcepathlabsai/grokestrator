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
    private var streamingTask: Task<Void, Never>?

    // Tracks the bubble currently being streamed into.
    private enum StreamKind { case message, thought }
    private var streamingID: UUID?
    private var streamingKind: StreamKind?

    init(driver: ConversationDriver) {
        self.driver = driver
    }

    /// Loads instance capabilities once (idempotent). Safe to call on view appear;
    /// for a live instance this also triggers the ACP initialize/session handshake.
    func loadCapabilities(force: Bool = false) {
        guard force || capabilities == nil else { return }
        let driver = self.driver
        Task { [weak self] in
            let caps = await driver.capabilities()
            if let caps { self?.capabilities = caps }
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

    /// Sends a prompt and streams the response into `entries`.
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        appendEntry(.userPrompt(trimmed))
        quickReplies = []
        isStreaming = true

        let driver = self.driver
        streamingTask = Task { [weak self] in
            do {
                let stream = try await driver.send(trimmed)
                for await update in stream {
                    // Task inherits the MainActor context, so this is a safe hop-back.
                    self?.handle(update)
                }
            } catch {
                self?.handle(.error(error.localizedDescription))
            }
            self?.endStreaming()
            self?.isStreaming = false
            self?.refreshUsage()
        }
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

    /// Cancels any in-flight turn (e.g. when the view goes away).
    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
        endStreaming()
        isStreaming = false
    }

    // MARK: - Update handling

    private func handle(_ update: ConversationUpdate) {
        switch update {
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
