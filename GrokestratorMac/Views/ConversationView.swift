import SwiftUI
import GrokestratorCore

/// The main working surface: a console-like transcript plus a prompt composer.
struct ConversationView: View {
    @Bindable var instance: InstanceItem
    @State private var draft = ""
    /// Highlighted row in the slash-command popup (keyboard navigation).
    @State private var slashHighlight = 0
    /// Set when the user dismisses the popup with Escape; reset when the token changes.
    @State private var slashDismissed = false

    private var conversation: ConversationViewModel { instance.conversation }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .bottom) {
                    if let perm = conversation.pendingPermission {
                        PermissionOverlay(request: perm) { option in
                            conversation.answerPermission(option)
                        }
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: conversation.pendingPermission)
            Divider()
            quickReplyBar
            if showSlashPopup {
                SlashCommandPopup(matches: slashMatches, highlight: slashHighlight) { applyCommand($0) }
            }
            composer
        }
        .navigationTitle(instance.name)
        .navigationSubtitle(instance.status.rawValue)
        .task {
            conversation.loadCapabilities()
            conversation.refreshUsage()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.entries) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if conversation.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }
                        .id(streamingMarkerID)
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .onChange(of: conversation.streamTick) {
                if let last = conversation.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(instance.name)…  (type / for commands)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .lineLimit(1...6)
                .onSubmit(send)
                .onChange(of: slashToken) { slashHighlight = 0; slashDismissed = false }
                .onKeyPress(action: handleComposerKey)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.glow, radius: canSend ? 6 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(12)
        .background(Theme.bgDeep)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conversation.isStreaming
    }

    // MARK: - Slash command popup

    /// The command token being typed: non-nil only while the draft is a leading
    /// `/word` with no space yet (i.e. the user is still typing the command name).
    private var slashToken: String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        return rest.contains(" ") ? nil : String(rest)
    }

    /// Commands matching the current token (prefix match; all commands for a bare `/`).
    private var slashMatches: [SlashCommand] {
        guard let token = slashToken else { return [] }
        let cmds = conversation.slashCommands
        guard !token.isEmpty else { return cmds }
        let q = token.lowercased()
        return cmds.filter { $0.name.lowercased().hasPrefix(q) }
    }

    private var showSlashPopup: Bool {
        !slashDismissed && !conversation.isStreaming
            && conversation.pendingPermission == nil && !slashMatches.isEmpty
    }

    /// Inserts the chosen command, leaving the cursor ready to type any argument.
    private func applyCommand(_ cmd: SlashCommand) {
        draft = "/\(cmd.name) "
        slashHighlight = 0
    }

    /// Routes arrow/return/escape to the popup while it's open; otherwise lets the
    /// field handle the key normally (returns `.ignored`).
    private func handleComposerKey(_ press: KeyPress) -> KeyPress.Result {
        guard showSlashPopup else { return .ignored }
        switch press.key {
        case .upArrow:
            slashHighlight = max(0, slashHighlight - 1); return .handled
        case .downArrow:
            slashHighlight = min(slashMatches.count - 1, slashHighlight + 1); return .handled
        case .return:
            if slashMatches.indices.contains(slashHighlight) { applyCommand(slashMatches[slashHighlight]) }
            return .handled
        case .escape:
            slashDismissed = true; return .handled
        default:
            return .ignored
        }
    }

    @ViewBuilder
    private var quickReplyBar: some View {
        let replies = conversation.quickReplies
        if !replies.isEmpty, !conversation.isStreaming, conversation.pendingPermission == nil {
            Group {
                if replies.count <= 3 && replies.allSatisfy({ $0.count <= 14 }) {
                    HStack(spacing: 8) { chips(replies); Spacer() }   // short → a row
                } else {
                    VStack(spacing: 6) { chips(replies) }              // long/many → a stack
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func chips(_ replies: [String]) -> some View {
        ForEach(replies, id: \.self) { reply in
            Button { conversation.send(reply) } label: {
                Text(reply).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize(horizontal: replies.count <= 3 && replies.allSatisfy { $0.count <= 14 }, vertical: false)
        }
    }

    private var streamingMarkerID: String { "streaming-marker" }

    private func send() {
        conversation.send(draft)
        draft = ""
    }
}

/// Renders one transcript entry with console-like, low-chrome styling.
private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userPrompt(let text):
            row(icon: "person.fill", tint: Theme.textMuted) {
                Text(text).font(Theme.body(14, .semibold)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        case .assistantMessage(let text):
            row(icon: "sparkle", tint: Theme.accent) {
                Text(text).font(Theme.body(14)).foregroundStyle(Theme.textBody).textSelection(.enabled)
            }
        case .assistantContent(let parts):
            row(icon: "sparkle", tint: Theme.accent) {
                AssistantContentView(parts: parts).font(Theme.body(14)).foregroundStyle(Theme.textBody)
            }
        case .thought(let text):
            note("💭 \(text)")
        case .update(let update):
            updateBody(update)
        }
    }

    @ViewBuilder
    private func updateBody(_ update: ConversationUpdate) -> some View {
        switch update {
        case .message(let text, _):
            row(icon: "sparkle", tint: .purple) {
                Text(text).textSelection(.enabled)
            }
        case .thought(let text, _):
            note("💭 \(text)")
        case .messageDelta, .thoughtDelta:
            // Handled by ConversationViewModel as live bubble growth, never rendered here.
            EmptyView()
        case .progressNote(let text, let phase, _):
            note("\(phase.map { "[\($0)] " } ?? "")\(text)")
        case .activityNote(let text, let kind, _):
            note("\(kind.map { "[\($0)] " } ?? "")\(text)")
        case .toolCallRequested(let info):
            mono("🔧 \(info.toolName)(\(argsString(info.arguments)))")
        case .permissionRequested(let info):
            row(icon: "lock.shield", tint: .orange) {
                Text("Permission requested: \(info.description)")
            }
        case .toolResultRecorded(let id, let isError):
            note("↳ tool \(id) \(isError ? "failed" : "ok")")
        case .sessionStatus(let s):
            note(s)
        case .error(let message):
            row(icon: "exclamationmark.triangle.fill", tint: .red) {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
        case .turnComplete:
            Divider().padding(.vertical, 2)
        case .unknownEvent(let raw):
            note(raw ?? "(unknown event)")
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func row<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12))
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, 24)
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.textBody)
            .padding(.leading, 24)
            .textSelection(.enabled)
    }

    private func argsString(_ args: [String: String]?) -> String {
        guard let args, !args.isEmpty else { return "" }
        return args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
    }
}

/// A floating card shown over the thread when the agent requests permission.
/// Lists the options as click targets (allow variants prominent); the choice is
/// sent back to the agent. (Free-text answers for agent *questions* are a follow-up.)
private struct PermissionOverlay: View {
    let request: PermissionRequestInfo
    let onChoose: (PermissionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grok is asking permission", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(request.description)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ForEach(request.options) { option in
                    Button {
                        onChoose(option)
                    } label: {
                        Text(option.label).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(option.isAllow ? Color.accentColor : Color.secondary)
                    .controlSize(.large)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.4)))
        .shadow(radius: 16, y: 6)
    }
}

/// Autocomplete list shown above the composer when the draft leads with `/`.
/// Filtered to the typed token; click or press Return to insert the highlighted one.
private struct SlashCommandPopup: View {
    let matches: [SlashCommand]
    let highlight: Int
    let onPick: (SlashCommand) -> Void

    var body: some View {
        // ScrollViewReader keeps the keyboard-highlighted row in view as the user
        // arrows past the visible window of a (potentially long) merged list.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, cmd in
                        Button { onPick(cmd) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(cmd.name)").font(Theme.mono(12)).foregroundStyle(Theme.accent)
                                if let hint = cmd.hint {
                                    Text(hint).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                                }
                                Spacer(minLength: 12)
                                if let d = cmd.description {
                                    Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: 280, alignment: .trailing)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == highlight ? Theme.accentSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Theme.radiusXs))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(cmd.id)
                    }
                }
            }
            .frame(maxHeight: 220)
            .onChange(of: highlight) {
                if matches.indices.contains(highlight) {
                    withAnimation(.snappy) { proxy.scrollTo(matches[highlight].id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
