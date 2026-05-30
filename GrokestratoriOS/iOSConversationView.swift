import SwiftUI
import GrokestratorCore

/// iPhone/iPad conversation view: transcript + composer + permission overlay.
/// Subscribes to the shared session on appear (PR B): the first event is a
/// `.snapshot` of existing history (so opening from anywhere shows where the
/// session left off), then live updates regardless of which device initiated.
struct iOSConversationView: View {
    @Bindable var instance: InstanceItem
    @FocusState private var composerFocused: Bool
    @State private var showInspector = false
    /// Drives the "clear chat history" confirmation — destructive and synced to
    /// every connected device, so we always confirm first.
    @State private var confirmingClear = false

    private var conversation: ConversationViewModel { instance.conversation }

    var body: some View {
        VStack(spacing: 0) {
            iOSConnectingBanner(conversation: conversation)
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
            if showSlashPopup {
                iOSSlashCommandPopup(matches: slashMatches, loading: conversation.commandsSettling) { applyCommand($0) }
            }
            composer
        }
        .background(Theme.bg.ignoresSafeArea())
        .environment(\.mediaLoader, conversation.mediaLoader)
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(conversation.entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear chat history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { conversation.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases the transcript for “\(instance.name)” on every connected device. The grok process keeps running.")
        }
        .inspector(isPresented: $showInspector) {
            // On iPad: trailing column. On iPhone: system collapses to a sheet.
            iOSInstanceInspectorView(instance: instance)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .task(id: instance.id) {
            // Live session subscription. `.task(id:)` auto-cancels on switch.
            conversation.startSubscription()
        }
        .onChange(of: conversation.focusToken) { composerFocused = true }
    }

    // MARK: - Slash command popup

    /// The token being typed: non-nil only while the draft is a leading
    /// `/word` with no space yet (still typing the command name).
    private var slashToken: String? {
        let draft = conversation.draft
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        return rest.contains(" ") ? nil : String(rest)
    }

    /// Commands matching the typed token (prefix match; all commands for a bare `/`).
    private var slashMatches: [SlashCommand] {
        guard let token = slashToken else { return [] }
        let cmds = conversation.slashCommands
        guard !token.isEmpty else { return cmds }
        let q = token.lowercased()
        return cmds.filter { $0.name.lowercased().hasPrefix(q) }
    }

    private var showSlashPopup: Bool {
        guard !conversation.isStreaming, conversation.pendingPermission == nil else { return false }
        return !slashMatches.isEmpty || (slashToken != nil && conversation.commandsSettling)
    }

    private func applyCommand(_ cmd: SlashCommand) {
        conversation.draft = "/\(cmd.name) "
        composerFocused = true
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
                .onChange(of: slashToken) { _, new in
                    if new != nil { conversation.refreshCapabilities() }
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))

            if conversation.isStreaming {
                Button(action: { conversation.cancelCurrent() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .shadow(color: .red.opacity(0.5), radius: 4)
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.glow, radius: canSend ? 6 : 0)
                }
                .disabled(!canSend)
            }
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

/// Renders one transcript entry. Media (`.assistantContent`) now renders via
/// `iOSAssistantContentView` — inline UIImage / AVPlayerViewController / QuickLook
/// for the corresponding `ContentPart` kinds (PR D).
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
                iOSAssistantContentView(parts: parts)
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

/// iOS slash-command popup: appears above the composer when the draft leads
/// with `/`. **Tap to insert** (no `.onKeyPress` arrow-nav available on iOS;
/// the keyboard generally lacks arrow keys anyway). Scrollable so a long
/// catalog (~30 commands) doesn't dominate the screen.
struct iOSSlashCommandPopup: View {
    let matches: [SlashCommand]
    var loading: Bool = false
    let onPick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading commands… (MCP servers)").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                ForEach(matches) { cmd in
                    Button { onPick(cmd) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("/\(cmd.name)").font(Theme.mono(13)).foregroundStyle(Theme.accent)
                            if let hint = cmd.hint {
                                Text(hint).font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                            }
                            Spacer(minLength: 12)
                            if let d = cmd.description {
                                Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .leading)
        .padding(6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// "Connecting to grok…" banner shown at the top of the conversation while
/// capabilities load. 750 ms grace before reveal so fast inits don't flicker.
struct iOSConnectingBanner: View {
    let conversation: ConversationViewModel
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Connecting to grok…")
                        .font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                    Text("(MCP servers can take a moment)")
                        .font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: visible)
        .task(id: conversation.sessionReady) {
            if conversation.sessionReady { visible = false; return }
            try? await Task.sleep(nanoseconds: 750_000_000)
            if !conversation.sessionReady { visible = true }
        }
        .onChange(of: conversation.sessionReady) { _, ready in
            if ready { visible = false }
        }
    }
}

