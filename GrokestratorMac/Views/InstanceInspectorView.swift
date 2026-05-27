import SwiftUI

/// Right-hand inspector (design/02 "Instance Inspector"). Reflects the currently
/// selected instance: its model + context window, MCP servers, and slash commands.
/// Capabilities are captured from the ACP `initialize` result (secret-free).
struct InstanceInspectorView: View {
    let instance: InstanceItem?

    var body: some View {
        Group {
            if let instance {
                content(for: instance)
                    .id(instance.id)               // repopulate when selection changes
                    .task(id: instance.id) { instance.conversation.loadCapabilities() }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(instance, caps: caps)

                if let caps {
                    if let model = caps.currentModel { modelSection(model, all: caps.models) }
                    mcpSection(caps.mcpServers)
                    commandsSection(caps.commands)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(instance.name)
                .font(Theme.display(16, .semibold))
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

    private func modelSection(_ model: AgentModel, all: [AgentModel]) -> some View {
        section("Model", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name ?? model.id).font(Theme.body(13, .semibold)).foregroundStyle(Theme.textBody)
                if let d = model.description {
                    Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                }
                if let tokens = model.contextTokens {
                    Text("\(tokens / 1000)K context window").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    @ViewBuilder
    private func mcpSection(_ servers: [MCPServerInfo]) -> some View {
        section("MCP Servers", systemImage: "server.rack", count: servers.count) {
            if servers.isEmpty {
                emptyRow("No MCP servers configured")
            } else {
                VStack(alignment: .leading, spacing: 6) {
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

    @ViewBuilder
    private func commandsSection(_ commands: [SlashCommand]) -> some View {
        section("Slash Commands", systemImage: "terminal", count: commands.count) {
            if commands.isEmpty {
                emptyRow("None advertised")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(commands) { cmd in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text("/\(cmd.name)").font(Theme.mono(12)).foregroundStyle(Theme.accent)
                                if let hint = cmd.hint {
                                    Text(hint).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                                }
                            }
                            if let d = cmd.description {
                                Text(d).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
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
}
