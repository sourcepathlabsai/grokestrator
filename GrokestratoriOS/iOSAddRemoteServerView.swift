import SwiftUI

/// Form to add a remote Grokestrator server (host + port). Same idea as the
/// Mac version but adapted to the iOS sheet conventions. Tailscale handles
/// transport encryption + tailnet ACLs (no app-level auth — per memory).
struct iOSAddRemoteServerView: View {
    @Bindable var model: iOSAppModel
    /// When set, the form edits this existing server instead of adding a new one.
    var editing: RemoteServerConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var localHost = ""
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
                    Text("Tailscale (works anywhere)")
                } footer: {
                    Text("The Mac must have its Grokestrator server enabled (Settings → Run server). Default port is 7847.")
                }

                Section {
                    TextField("e.g. 192.168.1.212", text: $localHost)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Local IP (optional, same Wi-Fi)")
                } footer: {
                    Text("When you're on the same Wi-Fi as the Mac, this direct connection is far faster — important for video and other large media. Grokestrator tries it first and falls back to Tailscale automatically when you're away.")
                }
            }
            .navigationTitle(editing == nil ? "Add Remote Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let e = editing {
                    name = e.name; host = e.host; localHost = e.localHost ?? ""; portText = String(e.port)
                }
            }
        }
    }
}
