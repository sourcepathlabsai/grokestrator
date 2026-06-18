import SwiftUI
import GrokestratorCore

/// A presentable identity for the brain backing a Node: a human label, an SF Symbol,
/// and a brand-ish tint. One resolver feeds both the catalog/picker labels and the
/// at-a-glance mini-icons in the sidebar + conversation header (hover → label).
///
/// Icons are semantic SF Symbols with brand tints (no bundled logo assets) — grok =
/// sparkle/cyan, Claude = asterisk/clay (its starburst mark), Gemini = sparkles, etc.
struct BrainDescriptor: Equatable {
    var label: String
    var systemImage: String
    var tint: Color
}

extension GrokestratorModel {
    /// Brand tints (kept here so every brain glyph reads consistently).
    static let grokTint = Theme.accent                                    // cyan
    static let claudeTint = Color(red: 0.84, green: 0.47, blue: 0.34)      // clay (#D67857-ish)

    /// The brain descriptor for a Node, resolved from its binding + (for command-based
    /// ACP nodes) its launch command + the catalog.
    func brainDescriptor(for item: InstanceItem) -> BrainDescriptor {
        let command = connections.first { $0.id == item.id }?.command ?? ""
        switch binding(for: item) {
        case .grok:
            return Self.acpDescriptor(command: command)
        case .inlineLegacy(let backend):
            if case .grokACP = backend { return Self.acpDescriptor(command: command) }
            return Self.descriptor(for: backend)
        case .profile(let id):
            let backend = brainCatalog.backend(for: id)
            if case .grokACP = backend { return Self.acpDescriptor(command: command) }
            return Self.descriptor(for: backend)
        case .dynamic(let defaultTier, _):
            return BrainDescriptor(label: "Dynamic · \(defaultTier.rawValue.capitalized)",
                                   systemImage: "arrow.triangle.branch", tint: Theme.accent)
        }
    }

    /// Descriptor for a concrete backend (catalog profile or legacy inline).
    static func descriptor(for backend: AgentBackend) -> BrainDescriptor {
        let label = defaultName(for: backend)
        switch backend {
        case .grokACP:
            return BrainDescriptor(label: label, systemImage: "sparkle", tint: grokTint)
        case .acpStdio(let command, _, let lbl):
            return acpDescriptor(command: command, label: lbl ?? label)
        case .gemini:
            return BrainDescriptor(label: label, systemImage: "sparkles", tint: .indigo)
        case .onboard:
            return BrainDescriptor(label: label, systemImage: "laptopcomputer", tint: .gray)
        case .openAICompatible(let baseURL, _, _):
            return apiDescriptor(label: label, baseURL: baseURL)
        }
    }

    /// Descriptor for a command-based ACP agent (grok / Claude Code / custom), keyed
    /// off the launch command (or an explicit label).
    static func acpDescriptor(command: String, label: String? = nil) -> BrainDescriptor {
        let name = label ?? acpAgentLabel(forCommand: command)
        let key = (name + " " + command).lowercased()
        if key.contains("claude") {
            return BrainDescriptor(label: name, systemImage: "asterisk", tint: claudeTint)
        }
        if key.contains("grok") {
            return BrainDescriptor(label: name, systemImage: "sparkle", tint: grokTint)
        }
        return BrainDescriptor(label: name, systemImage: "terminal", tint: .secondary)
    }

    /// Icon/tint for an OpenAI-compatible provider, by base-URL host.
    private static func apiDescriptor(label: String, baseURL: String) -> BrainDescriptor {
        let host = (URL(string: baseURL)?.host ?? baseURL).lowercased()
        let icon: String, tint: Color
        if host.contains("groq")                                   { icon = "bolt.fill";          tint = .orange }
        else if host.contains("cerebras")                          { icon = "cpu";                tint = .pink }
        else if host.contains("generativelanguage") || host.contains("googleapis") { icon = "sparkles"; tint = .indigo }
        else if host.contains("openai.com")                        { icon = "circle.hexagongrid"; tint = .green }
        else if host.contains("x.ai")                              { icon = "sparkle";            tint = grokTint }
        else if host.contains("localhost") || host.contains("127.0.0.1") { icon = "laptopcomputer"; tint = .gray }
        else                                                       { icon = "server.rack";        tint = .gray }
        return BrainDescriptor(label: label, systemImage: icon, tint: tint)
    }
}
