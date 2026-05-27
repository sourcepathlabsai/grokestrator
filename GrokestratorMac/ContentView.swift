import SwiftUI
import GrokestratorCore

struct ContentView: View {
    // Example usage of Core types (will light up once the local package is linked in Xcode)
    private let exampleServer = ServerAddress(
        name: "Dev Mac",
        tailscaleAddress: "100.64.0.1",
        port: 8080
    )

    var body: some View {
        NavigationSplitView {
            // Sidebar - placeholder for multi-server tabs later
            List {
                Section("Servers") {
                    Label(exampleServer.name, systemImage: "desktopcomputer")
                }
            }
            .navigationTitle("Grokestrator")
        } detail: {
            VStack(spacing: 16) {
                Text("Grokestrator Mac")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Hybrid client + server app (MVP foundation)")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Core package linked (example):")
                        .font(.headline)

                    Text("Server: \(exampleServer.name)")
                    Text("Tailscale: \(exampleServer.tailscaleAddress):\(exampleServer.port)")
                }
                .font(.system(.body, design: .monospaced))
                .padding()
                .background(.quaternary)
                .cornerRadius(8)

                Spacer()

                Text("Next steps in this branch: server process management, multi-tab session UI, basic connection to Core.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Overview")
        }
    }
}

#Preview {
    ContentView()
}
