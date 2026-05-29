import SwiftUI

/// Form to register a remote Grokestrator server. Tailscale handles encryption
/// and access at the network layer — just pick a friendly name and point at the
/// peer's MagicDNS hostname (e.g. `neo`) or its 100.x.y.z address + port.
struct AddRemoteServerView: View {
    @Bindable var model: GrokestratorModel
    /// When set, edits this existing server instead of adding a new one.
    var editing: RemoteServerConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var localHost: String = ""
    @State private var portText: String = "7847"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "Add Remote Server" : "Edit Server")
                .font(Theme.display(18, .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Connects to another Grokestrator instance over Tailscale. The other Mac must have its server enabled in Settings.")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)

            Form {
                LabeledContent("Name") {
                    TextField("e.g. Mac Mini", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Tailscale host") {
                    TextField("MagicDNS name or 100.x.y.z", text: $host).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Local IP") {
                    TextField("optional, e.g. 192.168.1.212", text: $localHost).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("7847", text: $portText).textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                }
            }

            Text("Local IP is used when you're on the same network as the Mac — a direct, full-speed link (best for video/large media). Grokestrator tries it first and falls back to Tailscale when you're away.")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(editing == nil ? "Add" : "Save") {
                    let port = UInt16(portText) ?? 7847
                    let display = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
                    let lan = localHost.trimmingCharacters(in: .whitespaces)
                    if let editing {
                        model.updateRemoteServer(RemoteServerConfig(
                            id: editing.id, name: display, host: host,
                            localHost: lan.isEmpty ? nil : lan, port: port))
                    } else {
                        model.addRemoteServer(name: display, host: host, localHost: lan.isEmpty ? nil : lan, port: port)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .onAppear {
            if let e = editing {
                name = e.name; host = e.host; localHost = e.localHost ?? ""; portText = String(e.port)
            }
        }
    }
}
