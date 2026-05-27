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
            Divider()
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
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.isStreaming)
        }
        .padding(12)
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
            row(icon: "person.fill", tint: .blue) {
                Text(text).fontWeight(.medium).textSelection(.enabled)
            }
        case .assistantMessage(let text):
            row(icon: "sparkle", tint: .purple) {
                Text(text).textSelection(.enabled)
            }
        case .assistantContent(let parts):
            row(icon: "sparkle", tint: .purple) {
                AssistantContentView(parts: parts)
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
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 24)
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .padding(.leading, 24)
            .textSelection(.enabled)
    }

    private func argsString(_ args: [String: String]?) -> String {
        guard let args, !args.isEmpty else { return "" }
        return args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
    }
}
