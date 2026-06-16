import SwiftUI
import GrokestratorCore

/// Sheet to create or edit a host MCP server in Grokestrator's registry. `stdio`
/// spawns a subprocess (npx/uvx/python — the common case); `http` connects to a
/// Streamable-HTTP endpoint. The registry is host-owned and model-agnostic: grok
/// Nodes get granted servers injected into `session/new`; API brains reach them via
/// the in-app MCP client (slice 2).
struct MCPServerEditorView: View {
    @Bindable var model: GrokestratorModel
    let existing: MCPServerConfig?
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable { case stdio, http; var id: String { rawValue } }

    @State private var name: String
    @State private var kind: Kind
    // stdio
    @State private var command: String
    @State private var argsText: String     // one arg per line
    @State private var envText: String       // KEY=VALUE per line
    // http
    @State private var url: String
    @State private var headersText: String   // Name: Value per line

    init(model: GrokestratorModel, existing: MCPServerConfig? = nil) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        switch existing?.transport {
        case .stdio(let command, let args, let env):
            _kind = State(initialValue: .stdio)
            _command = State(initialValue: command)
            _argsText = State(initialValue: args.joined(separator: "\n"))
            _envText = State(initialValue: env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
            _url = State(initialValue: ""); _headersText = State(initialValue: "")
        case .http(let url, let headers):
            _kind = State(initialValue: .http)
            _url = State(initialValue: url)
            _headersText = State(initialValue: headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
            _command = State(initialValue: ""); _argsText = State(initialValue: ""); _envText = State(initialValue: "")
        case nil:
            _kind = State(initialValue: .stdio)
            _command = State(initialValue: ""); _argsText = State(initialValue: ""); _envText = State(initialValue: "")
            _url = State(initialValue: ""); _headersText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").foregroundStyle(.tint)
                Text(existing == nil ? "New MCP Server" : "Edit MCP Server").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Name").frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                    TextField("e.g. filesystem, github", text: $name).textFieldStyle(.roundedBorder)
                }
                Picker("Transport", selection: $kind) {
                    Text("stdio (subprocess)").tag(Kind.stdio)
                    Text("http").tag(Kind.http)
                }
                .pickerStyle(.segmented)

                if kind == .stdio {
                    labeledField("Command", "npx", text: $command, mono: true)
                    multiline("Args", "one per line, e.g.\n-y\n@modelcontextprotocol/server-filesystem\n/path", text: $argsText)
                    multiline("Env", "KEY=VALUE per line (host-local)", text: $envText)
                } else {
                    labeledField("URL", "https://host/mcp", text: $url, mono: true)
                    multiline("Headers", "Name: Value per line", text: $headersText)
                }
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560)
    }

    private func labeledField(_ label: String, _ placeholder: String, text: Binding<String>, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.body, design: .monospaced) : .body)
        }
    }

    private func multiline(_ label: String, _ hint: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextEditor(text: text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var isValid: Bool {
        guard !name.trimmed.isEmpty else { return false }
        switch kind {
        case .stdio: return !command.trimmed.isEmpty
        case .http:  return !url.trimmed.isEmpty
        }
    }

    private func save() {
        let transport: MCPTransport
        switch kind {
        case .stdio:
            transport = .stdio(command: command.trimmed, args: parseLines(argsText), env: parseEnv(envText))
        case .http:
            transport = .http(url: url.trimmed, headers: parseHeaders(headersText))
        }
        if let existing {
            model.updateMCPServer(MCPServerConfig(id: existing.id, name: name.trimmed, transport: transport))
        } else {
            model.addMCPServer(name: name.trimmed, transport: transport)
        }
        dismiss()
    }

    private func parseLines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private func parseEnv(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in parseLines(s) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }
    private func parseHeaders(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in parseLines(s) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }
}
