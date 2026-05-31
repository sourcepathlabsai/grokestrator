import SwiftUI
import GrokestratorCore

/// iOS counterpart to the Mac `InstanceInspectorView`. Same data
/// (capabilities + usage), iOS-native styling. Presented via SwiftUI's
/// `.inspector(...)` modifier from `iOSConversationView` — on iPad that
/// puts it in a trailing column; on iPhone the system collapses it into a
/// sheet automatically.
struct iOSInstanceInspectorView: View {
    let instance: InstanceItem

    var body: some View {
        let caps = instance.conversation.capabilities
        let usage = instance.conversation.usage

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(caps: caps)

                if let caps {
                    if let model = caps.currentModel { modelSection(model) }
                    if let usage, usage.hasData { usageSection(usage) }
                    mcpSection(caps)
                    commandsSection(caps.commands)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Reading capabilities…").font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgDeep)
        .navigationTitle("Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: instance.id) {
            instance.conversation.loadCapabilities()
            instance.conversation.refreshUsage()
        }
    }

    // MARK: - Sections

    private func header(caps: AgentCapabilities?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(instance.name)
                .font(Theme.display(18, .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 6) {
                Text(instance.status.rawValue).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                if let v = caps?.agentVersion {
                    Text("· grok \(v)").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
            }
            if let cwd = caps?.workingDirectory {
                Text(cwd)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func modelSection(_ model: AgentModel) -> some View {
        section("Model", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name ?? model.id).font(Theme.body(14, .semibold)).foregroundStyle(Theme.textBody)
                if let d = model.description {
                    Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                }
                if let tokens = model.contextTokens {
                    Text("\(fmtTokens(tokens)) context window").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    private func usageSection(_ usage: SessionUsage) -> some View {
        section("Session Usage", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Context").font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        if let w = usage.contextWindow {
                            Text("\(fmtTokens(usage.totalTokens)) / \(fmtTokens(w))")
                                .font(Theme.mono(11)).foregroundStyle(Theme.textBody)
                            if let f = usage.fraction {
                                Text(String(format: "(%.1f%%)", f * 100))
                                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            }
                        } else {
                            Text(fmtTokens(usage.totalTokens)).font(Theme.mono(11)).foregroundStyle(Theme.textBody)
                        }
                    }
                    if let f = usage.fraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                                RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                                    .frame(width: max(2, geo.size.width * f))
                                    .shadow(color: Theme.glow, radius: 4)
                            }
                        }
                        .frame(height: 6)
                    }
                    HStack {
                        Spacer()
                        Button { instance.conversation.send("/compact") } label: {
                            Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(Theme.body(11, .medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .disabled(instance.conversation.isStreaming)
                        .help("Compress the conversation to free up context (sends /compact)")
                    }
                }
                Divider().overlay(Theme.border)
                Text("LAST TURN").font(Theme.display(10, .semibold)).foregroundStyle(Theme.textFaint)
                HStack(spacing: 14) {
                    if let v = usage.inputTokens { stat("input", v) }
                    if let v = usage.outputTokens { stat("output", v) }
                    if let v = usage.cachedReadTokens { stat("cached", v) }
                    if let v = usage.reasoningTokens { stat("reasoning", v) }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(fmtTokens(value)).font(Theme.mono(12)).foregroundStyle(Theme.textBody)
            Text(label).font(Theme.body(10)).foregroundStyle(Theme.textFaint)
        }
    }

    @ViewBuilder
    private func mcpSection(_ caps: AgentCapabilities) -> some View {
        let servers = caps.mcpServers
        let ready = caps.mcpTotal.map { (caps.mcpConnected ?? 0) >= $0 } ?? (caps.mcpToolCount != nil)
        section("MCP Servers", systemImage: "server.rack", count: servers.count) {
            VStack(alignment: .leading, spacing: 6) {
                if let status = caps.mcpStatusLabel {
                    HStack(spacing: 6) {
                        Circle().fill(ready ? Color.green : Color.yellow).frame(width: 5, height: 5)
                        Text(status).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                    }
                }
                if servers.isEmpty {
                    Text("No MCP servers configured").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                } else {
                    ForEach(servers) { server in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            Text(server.displayName).font(Theme.body(13, .medium)).foregroundStyle(Theme.textBody)
                            if let type = server.type {
                                Text(type).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.surface, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commandsSection(_ commands: [SlashCommand]) -> some View {
        section("Slash Commands", systemImage: "terminal", count: commands.count) {
            if commands.isEmpty {
                Text("None advertised").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tap to insert into the composer.")
                        .font(Theme.body(10))
                        .foregroundStyle(Theme.textFaint)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(commands) { cmd in
                                CommandRow(command: cmd) {
                                    instance.conversation.draft = "/\(cmd.name) "
                                    instance.conversation.requestComposerFocus()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    /// One tappable command row. Single tap inserts (iOS touch convention,
    /// not the double-click the Mac uses).
    private struct CommandRow: View {
        let command: SlashCommand
        let onInsert: () -> Void

        var body: some View {
            Button(action: onInsert) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("/\(command.name)").font(Theme.mono(13)).foregroundStyle(Theme.accent)
                        if let hint = command.hint {
                            Text(hint).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    if let d = command.description {
                        Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted).lineLimit(2)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String, count: Int? = nil,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text(title.uppercased()).font(Theme.display(11, .semibold)).foregroundStyle(Theme.textFaint)
                if let count { Text("\(count)").font(Theme.body(10)).foregroundStyle(Theme.textFaint) }
            }
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
        }
    }

    /// `512000` → `"512K"`, `16435` → `"16.4K"`, `812` → `"812"`. Mirrors the Mac.
    private func fmtTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return n >= 100_000 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }
}
