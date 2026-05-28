import SwiftUI
import GrokestratorCore

/// iPhone/iPad conversation view: transcript + composer + permission overlay.
/// Subscribes to the shared session on appear (PR B): the first event is a
/// `.snapshot` of existing history (so opening from anywhere shows where the
/// session left off), then live updates regardless of which device initiated.
struct iOSConversationView: View {
    @Bindable var instance: InstanceItem
    @FocusState private var composerFocused: Bool

    private var conversation: ConversationViewModel { instance.conversation }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .bottom) {
                    if let perm = conversation.pendingPermission {
                        iOSPermissionOverlay(request: perm) { option in
                            conversation.answerPermission(option)
                        }
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: conversation.pendingPermission)
            Divider().overlay(Theme.border)
            composer
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: instance.id) {
            // Live session subscription. `.task(id:)` auto-cancels on switch.
            await conversation.startSubscription()
        }
        .onChange(of: conversation.focusToken) { composerFocused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(conversation.entries) { entry in
                        iOSTranscriptRow(entry: entry)
                            .id(entry.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if conversation.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Theme.accent)
                            Text("Working…").font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                        }
                        .padding(.leading, 16)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .onChange(of: conversation.streamTick) {
                if let last = conversation.entries.last {
                    withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        @Bindable var conv = instance.conversation
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(instance.name)…", text: $conv.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body(15))
                .lineLimit(1...6)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.glow, radius: canSend ? 6 : 0)
            }
            .disabled(!canSend)
        }
        .padding(12)
        .background(Theme.bgDeep)
    }

    private var canSend: Bool {
        !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conversation.isStreaming
    }

    private func send() {
        conversation.send(conversation.draft)
        conversation.draft = ""
    }
}

// MARK: - Row + overlay

/// Renders one transcript entry. Text-only on iOS v1: media (`.assistantContent`)
/// is shown as text parts inline + an "Attachment" placeholder for non-text
/// parts. PR D adds real media rendering on iOS (UIKit equivalents of the
/// Mac's AppKit-based viewers).
private struct iOSTranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userPrompt(let text):
            row(icon: "person.fill", tint: Theme.textMuted) {
                Text(text).font(Theme.body(15, .semibold)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        case .assistantMessage(let text):
            row(icon: "sparkle", tint: Theme.accent) {
                Text(text).font(Theme.body(15)).foregroundStyle(Theme.textBody).textSelection(.enabled)
            }
        case .assistantContent(let parts):
            row(icon: "sparkle", tint: Theme.accent) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        if case .text(let text) = part {
                            Text(text).font(Theme.body(15)).foregroundStyle(Theme.textBody).textSelection(.enabled)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").foregroundStyle(Theme.textFaint)
                                Text("Attachment (PR D will render this)")
                                    .font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
        case .thought(let text):
            note("💭 \(text)")
        case .update(let update):
            updateRow(update)
        }
    }

    @ViewBuilder
    private func updateRow(_ update: ConversationUpdate) -> some View {
        switch update {
        case .message(let text, _):
            row(icon: "sparkle", tint: .purple) {
                Text(text).font(Theme.body(15)).textSelection(.enabled)
            }
        case .thought(let text, _):
            note("💭 \(text)")
        case .progressNote(let text, let phase, _):
            note("\(phase.map { "[\($0)] " } ?? "")\(text)")
        case .activityNote(let text, let kind, _):
            note("\(kind.map { "[\($0)] " } ?? "")\(text)")
        case .toolCallRequested(let info):
            mono("🔧 \(info.toolName)")
        case .error(let message):
            row(icon: "exclamationmark.triangle.fill", tint: .red) {
                Text(message).foregroundStyle(.red).font(Theme.body(13)).textSelection(.enabled)
            }
        case .turnComplete:
            Divider().overlay(Theme.border).padding(.vertical, 2)
        case .userPrompt, .messageDelta, .thoughtDelta:
            EmptyView()
        case .permissionRequested, .toolResultRecorded, .sessionStatus, .unknownEvent:
            EmptyView()
        }
    }

    @ViewBuilder
    private func row<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.body(12)).foregroundStyle(Theme.textMuted).padding(.leading, 24)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.textBody).padding(.leading, 24).textSelection(.enabled)
    }
}

/// Floating card over the bottom of the transcript when a permission is
/// awaiting a decision. Same behavior as Mac's overlay — buttons send the
/// chosen `optionId` back over the wire; first device to answer wins.
private struct iOSPermissionOverlay: View {
    let request: PermissionRequestInfo
    let onChoose: (PermissionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Grok is asking permission", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(request.description)
                .font(.callout)
                .textSelection(.enabled)
            VStack(spacing: 8) {
                ForEach(request.options) { option in
                    Button { onChoose(option) } label: {
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
