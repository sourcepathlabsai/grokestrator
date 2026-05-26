import SwiftUI
import GrokestratorCore

struct ContentView: View {
    // Example of using Core types (will resolve once the local package is added in Xcode)
    private let sampleServers: [ServerAddress] = [
        ServerAddress(name: "Dev Mac", tailscaleAddress: "100.64.0.1", port: 8080),
        ServerAddress(name: "Research Rig", tailscaleAddress: "100.64.12.34", port: 8080)
    ]

    var body: some View {
        NavigationStack {
            List(sampleServers) { server in
                VStack(alignment: .leading) {
                    Text(server.name)
                        .font(.headline)
                    Text("\(server.tailscaleAddress):\(server.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Grokestrator")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
}
