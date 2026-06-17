import SwiftUI
import AppKit
import GrokestratorCore

/// Guided setup for adding **Claude Code** as a Node (a "Code Warrior" that the
/// team can delegate coding to). Detects the prerequisite chain, auto-installs the
/// parts Grokestrator can (node via Homebrew, the ACP adapter via npm), and shows
/// copy-paste instructions for the parts only the user can do (Claude Code itself,
/// Homebrew). When ready, creates the Node pointed at the resolved adapter.
struct ClaudeCodeSetupView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    @State private var probe: ClaudeCodeSetup.Probe?
    @State private var checking = true
    @State private var busy: String?          // which step is installing (nil = idle)
    @State private var log = ""

    @State private var name = "Code Warrior"
    @State private var workingDirectory = ""

    private let brewInstallCmd = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill").foregroundStyle(.tint)
                Text("Add Claude Code Agent").font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: { Label("Re-check", systemImage: "arrow.clockwise") }
                    .disabled(checking || busy != nil)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Claude Code runs as a Node over ACP via the `claude-code-acp` adapter. Grokestrator installs what it can; you handle Claude Code + Homebrew.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let probe {
                        claudeRow(probe)
                        homebrewRow(probe)
                        nodeRow(probe)
                        adapterRow(probe)
                    } else if checking {
                        ProgressView("Checking prerequisites…").controlSize(.small)
                    }

                    if !log.isEmpty {
                        Text("Output").font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(log).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    Divider()
                    agentFields
                }
                .padding()
            }

            Divider()
            HStack {
                if let probe, !probe.ready {
                    Text("Finish the steps above to create the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Agent") { create() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!(probe?.ready ?? false) || name.trimmed.isEmpty || busy != nil)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
        .task { await refresh() }
    }

    // MARK: Rows

    private func claudeRow(_ p: ClaudeCodeSetup.Probe) -> some View {
        row(ok: p.claudeOK, title: "Claude Code", detail: p.claudePath ?? "not found") {
            if !p.claudeOK {
                instruction("Install Claude Code (claude.com/claude-code), then run:", "claude /login")
            }
        }
    }

    private func homebrewRow(_ p: ClaudeCodeSetup.Probe) -> some View {
        row(ok: p.homebrewOK, title: "Homebrew", detail: p.brewPath ?? "not found") {
            if !p.homebrewOK { instruction("Install Homebrew, then Re-check:", brewInstallCmd) }
        }
    }

    private func nodeRow(_ p: ClaudeCodeSetup.Probe) -> some View {
        row(ok: p.nodeOK, title: "Node / npm", detail: p.nodePath ?? "not found") {
            if !p.nodeOK {
                if p.homebrewOK {
                    installButton("node", title: "Install node") { await ClaudeCodeSetup.installNode() }
                } else {
                    Text("Needs Homebrew first.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func adapterRow(_ p: ClaudeCodeSetup.Probe) -> some View {
        row(ok: p.adapterOK, title: "ACP adapter", detail: p.adapterPath ?? "not installed") {
            if !p.adapterOK {
                if p.nodeOK {
                    installButton("adapter", title: "Install adapter") { await ClaudeCodeSetup.installAdapter() }
                } else {
                    Text("Needs node first.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row<Action: View>(ok: Bool, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                action()
            }
            Spacer()
        }
    }

    private func installButton(_ step: String, title: String, run: @escaping () async -> (output: String, exitCode: Int32)) -> some View {
        Button {
            Task {
                busy = step
                log += "\n$ \(title)…\n"
                let r = await run()
                log += r.output
                log += "\n(exit \(r.exitCode))\n"
                busy = nil
                await refresh()
            }
        } label: {
            if busy == step { ProgressView().controlSize(.small) } else { Text(title) }
        }
        .disabled(busy != nil)
    }

    private func instruction(_ text: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(command).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .padding(4).background(Theme.bgDeep).clipShape(RoundedRectangle(cornerRadius: 4))
                Button { copy(command) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
        }
    }

    // MARK: Agent fields

    private var agentFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Name").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                TextField("Code Warrior", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Working directory").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                TextField("the project to code in", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button { pickDirectory() } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
            }
            Text("Creates a Node backed by Claude Code, pre-set with an implementation role. Delegate coding tasks to it from an orchestrator.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Actions

    private func refresh() async {
        checking = true
        probe = await ClaudeCodeSetup.detect()
        checking = false
    }

    private func create() {
        guard let adapter = probe?.adapterPath else { return }
        let finalName = name.trimmed.isEmpty ? "Code Warrior" : name.trimmed
        let cwd = workingDirectory.trimmed.isEmpty ? nil
            : (workingDirectory.trimmed as NSString).expandingTildeInPath
        let role = """
        You are \(finalName), the team's implementation specialist (Claude Code). \
        You write, build, run, and verify code in the working directory. Implement the \
        task you're handed end-to-end, then report exactly what you changed and how you verified it.
        """
        model.addRealConnection(name: finalName, command: adapter, arguments: [],
                                workingDirectory: cwd, rolePrompt: role, brain: .grok)
        dismiss()
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url.path }
    }
}
