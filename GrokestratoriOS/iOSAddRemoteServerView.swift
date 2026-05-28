import SwiftUI

/// Form to add a remote Grokestrator server (host + port). Same idea as the
/// Mac version but adapted to the iOS sheet conventions. Tailscale handles
/// transport encryption + tailnet ACLs (no app-level auth — per memory).
struct iOSAddRemoteServerView: View {
    @Bindable var model: iOSAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var portText = "7847"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Mac Mini", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("MagicDNS name or 100.x.y.z", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Server")
                } footer: {
                    Text("The other device must have its Grokestrator server enabled (Settings → Run server). Default port is 7847.")
                }
            }
            .navigationTitle("Add Remote Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let port = UInt16(portText) ?? 7847
                        let display = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
                        model.addRemoteServer(name: display, host: host, port: port)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
