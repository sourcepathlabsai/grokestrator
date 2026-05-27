import SwiftUI
import GrokestratorCore

/// The main working surface: a console-like transcript plus a prompt composer.
struct ConversationView: View {
    @Bindable var instance: InstanceItem
    @State private var draft = ""

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
            composer
        }
        .navigationTitle(instance.name)
        .navigationSubtitle(instance.status.rawValue)
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
            TextField("Message \(instance.name)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .lineLimit(1...6)
                .onSubmit(send)
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
