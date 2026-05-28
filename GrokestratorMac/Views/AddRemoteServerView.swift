import SwiftUI

/// Form to register a remote Grokestrator server. Tailscale handles encryption
/// and access at the network layer — just pick a friendly name and point at the
/// peer's MagicDNS hostname (e.g. `neo`) or its 100.x.y.z address + port.
struct AddRemoteServerView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "7847"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Remote Server")
                .font(Theme.display(18, .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Connects to another Grokestrator instance over Tailscale. The other Mac must have its server enabled in Settings.")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)

            Form {
                LabeledContent("Name") {
                    TextField("e.g. Mac Mini", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Host") {
                    TextField("MagicDNS name or 100.x.y.z", text: $host).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("7847", text: $portText).textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    let port = UInt16(portText) ?? 7847
                    let display = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
                    model.addRemoteServer(name: display, host: host, port: port)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
