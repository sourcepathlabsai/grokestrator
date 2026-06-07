import SwiftUI
import GrokestratorCore

/// iPhone/iPad conversation view: transcript + composer + permission overlay.
/// Subscribes to the shared session on appear (PR B): the first event is a
/// `.snapshot` of existing history (so opening from anywhere shows where the
/// session left off), then live updates regardless of which device initiated.
struct iOSConversationView: View {
    @Bindable var instance: InstanceItem
    /// Plain `Bool` (not `@FocusState`) because the composer is a
    /// `UIViewRepresentable` that drives/observes first-responder via this binding.
    @State private var composerFocused = false
    @State private var showInspector = false
    /// Drives the "clear chat history" confirmation — destructive and synced to
    /// every connected device, so we always confirm first.
    @State private var confirmingClear = false
    /// Bumped whenever the user sends, to force the transcript back to the
    /// bottom (and re-arm stick) even if they had scrolled up to read.
    @State private var pinToken = 0

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
                    } else if let question = conversation.pendingUserQuestion {
                        iOSUserQuestionOverlay(request: question) { index, answer in
                            conversation.answerUserQuestion(questionIndex: index, answer: answer)
                        }
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: conversation.pendingPermission)
                .animation(.snappy, value: conversation.pendingUserQuestion)
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
        // Switching Connections should land on the newest content, not inherit
        // wherever the previous transcript was scrolled.
        .onChange(of: instance.id) { pinToken += 1 }
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
        guard !conversation.isStreaming, conversation.pendingPermission == nil, conversation.pendingUserQuestion == nil else { return false }
        return !slashMatches.isEmpty || (slashToken != nil && conversation.commandsSettling)
    }

    private func applyCommand(_ cmd: SlashCommand) {
        conversation.draft = "/\(cmd.name) "
        composerFocused = true
    }

    // MARK: - Transcript

    private var transcriptItems: [TranscriptListItem] {
        var items = conversation.entries.map { TranscriptListItem.entry($0) }
        if conversation.isStreaming { items.append(.indicator(conversation.activityStatus)) }
        return items
    }

    private var transcript: some View {
        // Console-style stick-to-bottom over a VIRTUALIZED list: only on-screen
        // rows are built, so a long live stream costs ~viewport, not the whole
        // transcript. Auto-follows the reply only while already at bottom.
        VirtualizedStickyList(items: transcriptItems, tick: conversation.streamTick,
                              pinToken: pinToken, rowSpacing: 10) { item in
            switch item {
            case .entry(let entry):
                iOSTranscriptRow(entry: entry, streamingMessageID: conversation.streamingMessageID)
            case .indicator(let status):
                ThinkingIndicator(status: status).padding(.leading, 16)
            }
        }
        .background(Theme.bg)
    }

    // MARK: - Composer

    private var composer: some View {
        @Bindable var conv = instance.conversation
        return HStack(alignment: .bottom, spacing: 8) {
            // Backed by a real UITextView so the prompt reflows at the
            // composer's current width — both when the panel resizes it and for
            // a freshly typed line in the narrowed box.
            ComposerTextView(
                text: $conv.draft,
                placeholder: "Message \(instance.name)…",
                fontSize: 15,
                isFocused: $composerFocused,
                onSubmit: send
            )
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
        pinToken += 1
    }
}

// MARK: - Row + overlay

/// A completed turn's thinking, collapsed into an expandable "Thought process"
/// disclosure (tap the caret to re-expose). Collapsed by default once the answer
/// lands. Live-only — history never persists thoughts, so it shows only in the
/// active session.
private struct iOSThoughtProcessView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Thought process").font(Theme.body(12, .medium))
                }
                .foregroundStyle(Theme.textFaint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A completed turn's tool calls + progress notes, collapsed into an expandable
/// disclosure (mirrors `iOSThoughtProcessView`). Collapsed by default once the
/// answer lands. Live-only — history never persists these.
private struct iOSToolActivityView: View {
    let lines: [String]
    @State private var expanded = false

    private var toolCount: Int { lines.lazy.filter { $0.hasPrefix("🔧") }.count }
    private var title: String {
        toolCount > 0 ? "\(toolCount) tool call\(toolCount == 1 ? "" : "s")" : "Activity"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                    Text(title).font(Theme.body(12, .medium))
                }
                .foregroundStyle(Theme.textFaint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// grok's live task checklist (touch-sized), mirroring the Mac `PlanView`. A
/// single titled card that updates in place as grok re-broadcasts the plan.
/// Live-only — never persisted.
private struct iOSPlanView: View {
    let plan: AgentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Plan").font(Theme.body(13, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(plan.completedCount)/\(plan.entries.count) done")
                    .font(Theme.body(12)).foregroundStyle(Theme.textFaint)
            }
            ForEach(plan.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.glyph(entry.status))
                        .font(.system(size: 14))
                        .foregroundStyle(Self.glyphColor(entry.status))
                        .frame(width: 18)
                    Text(entry.content)
                        .font(Theme.body(14))
                        .foregroundStyle(entry.status == .completed ? Theme.textFaint : Theme.textBody)
                        .strikethrough(entry.status == .completed, color: Theme.textFaint)
                    if entry.priority == .high, entry.status != .completed {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
        .padding(.leading, 24)
    }

    private static func glyph(_ status: AgentPlan.Entry.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private static func glyphColor(_ status: AgentPlan.Entry.Status) -> Color {
        switch status {
        case .pending: return Theme.textFaint
        case .inProgress: return Theme.accent
        case .completed: return .green
        }
    }
}

/// Renders one transcript entry. Media (`.assistantContent`) now renders via
/// `iOSAssistantContentView` — inline UIImage / AVPlayerViewController / QuickLook
/// for the corresponding `ContentPart` kinds (PR D).
private struct iOSTranscriptRow: View {
    let entry: TranscriptEntry
    /// The id of the bubble currently being streamed into (if any). That one
    /// renders as plain text while it grows, then switches to Markdown on finalize
    /// — re-parsing a fast-growing message every refresh is the streaming hot path.
    var streamingMessageID: UUID? = nil

    var body: some View {
        switch entry.kind {
        case .userPrompt(let text):
            row(icon: "person.fill", tint: Theme.textMuted) {
                Text(text).font(Theme.body(15, .semibold)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        case .assistantMessage(let text):
            row(icon: "sparkle", tint: Theme.accent) {
                if entry.id == streamingMessageID {
                    Text(text).font(Theme.body(15)).foregroundStyle(Theme.textBody).textSelection(.enabled)
                } else {
                    MarkdownText(text, baseSize: 15)
                }
            }
        case .assistantContent(let parts):
            row(icon: "sparkle", tint: Theme.accent) {
                iOSAssistantContentView(parts: parts)
            }
        case .thought(let text):
            note("💭 \(text)")
        case .thoughtSummary(let text):
            iOSThoughtProcessView(text: text)
        case .toolActivitySummary(let lines):
            iOSToolActivityView(lines: lines)
        case .plan(let plan):
            iOSPlanView(plan: plan)
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
        case .planUpdated(let plan):
            // Plans normally render via the `.plan` entry kind (live, in-place);
            // render the card too if one ever arrives wrapped as `.update`.
            iOSPlanView(plan: plan)
        case .userPrompt, .messageDelta, .thoughtDelta:
            EmptyView()
        case .permissionRequested, .userQuestionRequested, .toolResultRecorded, .sessionStatus, .unknownEvent:
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

/// A floating card shown when the agent asks a structured question
/// (`_x.ai/ask_user_question`). Mirrors `iOSPermissionOverlay` but renders each
/// question's prompt + options (label + muted description) plus a free-text
/// field for an "Other" answer. Tuned for touch (bigger tap targets).
private struct iOSUserQuestionOverlay: View {
    let request: UserQuestionInfo
    /// (questionIndex, answer) — answer is a chosen option label or free text.
    let onAnswer: (Int, String) -> Void

    @State private var freeText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Grok is asking a question", systemImage: "questionmark.bubble")
                .font(.headline)
                .foregroundStyle(Theme.accent)

            ForEach(Array(request.questions.enumerated()), id: \.offset) { qIdx, question in
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.prompt)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(question.options) { option in
                        Button {
                            onAnswer(qIdx, option.label)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label).font(Theme.body(15))
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(iOSUserQuestionOptionButtonStyle())
                    }
                }
            }

            // Free-text / "Other" path — answers the first question.
            HStack(spacing: 8) {
                TextField("Type a different answer…", text: $freeText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(Theme.body(15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    .submitLabel(.send)
                    .onSubmit { submitFreeText() }
                Button {
                    submitFreeText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(freeText.isEmpty ? Theme.textMuted : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(maxWidth: 540)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }

    private func submitFreeText() {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(0, trimmed)
    }
}

private struct iOSUserQuestionOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .foregroundStyle(Theme.textBody)
            .opacity(configuration.isPressed ? 0.7 : 1)
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

