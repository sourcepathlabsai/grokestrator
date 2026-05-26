import Foundation

/// Persistent configuration for the Grokestrator server component.
/// The Mac app (in its server role) owns and applies this.
public struct ServerConfiguration: Codable, Sendable, Equatable {
    public var serverName: String
    public var port: Int
    public var bindAddress: String          // "0.0.0.0" or "127.0.0.1" for local-only during dev
    public var autoStartOnLaunch: Bool
    public var instances: [ManagedInstance]

    public init(
        serverName: String = "Dev Mac",
        port: Int = 8080,
        bindAddress: String = "0.0.0.0",
        autoStartOnLaunch: Bool = true,
        instances: [ManagedInstance] = []
    ) {
        self.serverName = serverName
        self.port = port
        self.bindAddress = bindAddress
        self.autoStartOnLaunch = autoStartOnLaunch
        self.instances = instances
    }

    /// Default sensible starting configuration for a powerful dev Mac.
    public static var defaultConfiguration: ServerConfiguration {
        ServerConfiguration(
            serverName: "Dev Mac",
            port: 8080,
            bindAddress: "0.0.0.0",
            autoStartOnLaunch: true,
            instances: [
                ManagedInstance(
                    name: "primary",
                    command: "/opt/homebrew/bin/grok",
                    arguments: ["agent", "serve", "--stdio"],
                    autoRestart: true
                )
            ]
        )
    }
}
