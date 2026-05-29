import SwiftUI

/// Branded "Grokestrator Help" window — a short, friendly tour of the UI.
/// The app is simple, so this stays to a handful of topics rather than a full
/// manual. Opened from the Help menu via `CommandGroup(replacing: .help)`.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                ForEach(Self.topics) { topic in
                    TopicRow(topic: topic)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(width: 460, height: 540)
        .background(
            LinearGradient(colors: [Theme.bg, Theme.bgDeep],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Grokestrator Help")
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("A quick tour. Grokestrator runs and orchestrates grok agents — each connection is one agent you chat with.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Topics

    private struct Topic: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private static let topics: [Topic] = [
        Topic(
            icon: "sidebar.left",
            title: "Connections",
            body: """
            The sidebar lists your connections, grouped by where they run — \
            “This Mac” first, then any remote servers. Add one with the + button: \
            a Local Connection launches a grok agent on this Mac, a Remote Server \
            links to another Grokestrator over Tailscale. The colored dot shows \
            status (green = running, yellow = starting/stopping, red = crashed). \
            Right-click a local connection to Stop, Archive (reversible), or \
            Delete it permanently. Archived ones tuck into the footer.
            """
        ),
        Topic(
            icon: "text.bubble",
            title: "Chatting with an agent",
            body: """
            Type in the composer and press Return to send. Start with “/” to pick \
            a slash command the agent supports. While the agent works you’ll see \
            its thinking stream live — that clears once the final answer lands. \
            The Stop button cancels the current turn. When the agent asks you to \
            choose, quick-reply buttons appear; when it needs permission, a prompt \
            floats over the thread. The trash icon clears the whole transcript.
            """
        ),
        Topic(
            icon: "antenna.radiowaves.left.and.right",
            title: "Across your devices",
            body: """
            Share a connection with remote clients and you can pick up the same \
            conversation from an iPhone or iPad over Tailscale. The Mac hosting \
            the agent is the source of truth, so every device sees the identical \
            transcript — including prompts typed elsewhere, and a cleared history \
            clears everywhere at once.
            """
        ),
    ]

    private struct TopicRow: View {
        let topic: Topic
        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: topic.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                    .shadow(color: Theme.glow, radius: 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(topic.title)
                        .font(Theme.display(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(topic.body)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border))
        }
    }
}
