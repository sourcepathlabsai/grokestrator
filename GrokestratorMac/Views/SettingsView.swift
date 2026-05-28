import SwiftUI

/// App Settings: today, just the server toggle. Off by default; enabling opens
/// the listener on the chosen port. Tailscale handles encryption / access.
struct SettingsView: View {
    @Bindable var model: GrokestratorModel

    var body: some View {
        TabView {
            serverTab
                .tabItem { Label("Server", systemImage: "network") }
                .frame(minWidth: 520, minHeight: 320)
        }
    }

    private var serverTab: some View {
        Form {
            Section {
                Toggle("Run server on this Mac", isOn: $model.serverEnabled)
                Text("Lets other Grokestrator clients (Mac or iOS) drive this Mac's grok instances over Tailscale. Off by default. Tailscale is the trust boundary — no extra authentication is enforced at this layer.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textMuted)
            } header: {
                Text("Remote Access").font(Theme.display(12, .semibold))
            }

            Section {
                Stepper(value: $model.serverPort, in: 1024...65535) {
                    HStack {
                        Text("Port")
                        Spacer()
                        Text("\(model.serverPort)").font(Theme.mono(12)).foregroundStyle(Theme.textBody)
                    }
                }
                .disabled(!model.serverEnabled)

                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                }
            } header: {
                Text("Listener").font(Theme.display(12, .semibold))
            }
        }
        .padding(20)
    }

    private var statusText: String {
        // The server's state is on the actor; we display the user's intent here
        // and rely on the model's didSet to apply it. A live status indicator is
        // a small follow-up.
        model.serverEnabled ? "Listening on port \(model.serverPort)" : "Stopped"
    }
    private var statusColor: Color { model.serverEnabled ? .green : .secondary }
}
