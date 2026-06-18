import SwiftUI
import GrokestratorCore

/// Right-hand inspector (design/02 "Instance Inspector"). Reflects the currently
/// selected instance: model + context window, session usage, MCP servers, and
/// slash commands; also surfaces a Stop control for the underlying grok process.
///
/// Capabilities are captured from the ACP `initialize` result (secret-free) and
/// kept current by `available_commands_update`. Usage is captured live from
/// `session/update._meta.totalTokens` and finalized from the `session/prompt`
/// result `_meta` (input/output/cached/reasoning breakdown).
struct InstanceInspectorView: View {
    let instance: InstanceItem?
    @Bindable var model: GrokestratorModel
    /// Recent design-oracle verdicts for the selected node (read from the ledger; not
    /// reactive, so we reload on selection + via the section's refresh).
    @State private var oracleEvents: [GovernanceEvent] = []

    var body: some View {
        Group {
            if let instance {
                content(for: instance)
                    .id(instance.id)               // repopulate when selection changes
                    .task(id: instance.id) {
                        instance.conversation.loadCapabilities()
                        instance.conversation.refreshUsage()
                        oracleEvents = OracleLedger.shared.recent(nodeID: instance.id, limit: 30)
                    }
            } else {
                ContentUnavailableView("No instance", systemImage: "sidebar.right",
                                       description: Text("Select a connection to inspect it."))
            }
        }
        .background(Theme.bgDeep)
    }

    @ViewBuilder
    private func content(for instance: InstanceItem) -> some View {
        let caps = instance.conversation.capabilities
        let usage = instance.conversation.usage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(instance, caps: caps)

                if let caps {
                    if let model = caps.currentModel { modelSection(model) }
                    if let usage, usage.hasData { usageSection(usage) }
                    mcpSection(caps)
                    oracleSection(instance)
                    commandsSection(caps.commands, instance: instance)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading capabilities…").font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sections

    private func header(_ instance: InstanceItem, caps: AgentCapabilities?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(instance.name)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                stopButton(instance)
            }
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

    @ViewBuilder
    private func stopButton(_ instance: InstanceItem) -> some View {
        if instance.status == .running || instance.status == .starting {
            Button(role: .destructive) {
                model.stop(instance)
            } label: {
                Label("Stop", systemImage: "stop.circle").font(Theme.body(11, .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Terminate this grok process")
        }
    }

    private func modelSection(_ model: AgentModel) -> some View {
        section("Model", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name ?? model.id).font(Theme.body(13, .semibold)).foregroundStyle(Theme.textBody)
                if let d = model.description {
                    Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                }
                if let tokens = model.contextTokens {
                    Text("\(fmtTokens(tokens)) context window").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    /// Token usage: a context-window bar (total / window) and the last turn's
    /// input / output / cached / reasoning breakdown.
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
                            Text("\(fmtTokens(usage.totalTokens))").font(Theme.mono(11)).foregroundStyle(Theme.textBody)
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
                    if let instance {
                        HStack {
                            Spacer()
                            Button { instance.conversation.send("/compact") } label: {
                                Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                                    .font(Theme.body(10, .medium))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .tint(Theme.accent)
                            .disabled(instance.conversation.isStreaming)
                            .help("Compress the conversation to free up context (sends /compact)")
                        }
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

    /// Design-oracle ledger: what the (shadow) oracle would have decided for this node's
    /// actions — the evidence it's working. Observe-only; nothing is enforced yet.
    private func oracleSection(_ instance: InstanceItem) -> some View {
        section("Design Oracle", systemImage: "lock.shield", count: oracleEvents.isEmpty ? nil : oracleEvents.count) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    oracleStat("allow", oracleEvents.filter { $0.outcome == "allow" }.count, .green)
                    oracleStat("escalate", oracleEvents.filter { $0.outcome == "escalate" }.count, .orange)
                    oracleStat("block", oracleEvents.filter { $0.outcome == "block" }.count, .red)
                    Spacer()
                    Button { oracleEvents = OracleLedger.shared.recent(nodeID: instance.id, limit: 30) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless).help("Refresh verdicts")
                }
                Text("Shadow — observed, not enforced. Recorded to `oracle-verdicts.jsonl`.")
                    .font(Theme.body(10)).foregroundStyle(Theme.textFaint)
                if oracleEvents.isEmpty {
                    Text("No verdicts yet — the oracle records here as this node acts.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textMuted).padding(.top, 2)
                } else {
                    Divider().overlay(Theme.border)
                    ForEach(oracleEvents.prefix(12)) { verdictRow($0) }
                }
            }
        }
    }

    private func oracleStat(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(Theme.mono(13)).foregroundStyle(value > 0 ? tint : Theme.textFaint)
            Text(label).font(Theme.body(9)).foregroundStyle(Theme.textFaint)
        }
    }

    private func verdictRow(_ e: GovernanceEvent) -> some View {
        let tint: Color = e.outcome == "block" ? .red : (e.outcome == "escalate" ? .orange : .green)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(e.outcome.uppercased()).font(Theme.mono(9)).foregroundStyle(tint)
                Text(e.verb).font(Theme.mono(10)).foregroundStyle(Theme.textBody)
                if let se = e.sideEffect { Text("· \(se)").font(Theme.body(9)).foregroundStyle(Theme.textFaint) }
                Spacer()
            }
            if let p = e.payload, !p.isEmpty {
                Text(p).font(Theme.mono(9)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
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
                    emptyRow("No MCP servers configured")
                } else {
                    ForEach(servers) { server in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            Text(server.displayName).font(Theme.body(12, .medium)).foregroundStyle(Theme.textBody)
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

    /// Slash commands are merged (advertised ∪ documented built-ins) so the list
    /// is long enough to need its own scroll. Capped at ~280pt so the inspector's
    /// other sections stay visible without the whole panel becoming a single scroll.
    /// Rows double-click to insert `/<name> ` into the composer and focus it.
    @ViewBuilder
    private func commandsSection(_ commands: [SlashCommand], instance: InstanceItem) -> some View {
        section("Slash Commands", systemImage: "terminal", count: commands.count) {
            if commands.isEmpty {
                emptyRow("None advertised")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Double-click to insert into the composer.")
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
                        .padding(.trailing, 4)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
    }

    /// A clickable command row with a hover highlight; double-click inserts.
    private struct CommandRow: View {
        let command: SlashCommand
        let onInsert: () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("/\(command.name)").font(Theme.mono(12)).foregroundStyle(Theme.accent)
                    if let hint = command.hint {
                        Text(hint).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                if let d = command.description {
                    Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusXs))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onInsert() }
            .help("Double-click to insert /\(command.name)")
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

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(Theme.body(11)).foregroundStyle(Theme.textFaint)
    }

    /// `512000` → `"512K"`, `16435` → `"16.4K"`, `812` → `"812"`.
    private func fmtTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return n >= 100_000 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }
}
