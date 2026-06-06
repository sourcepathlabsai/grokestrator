import SwiftUI

/// The live "agent is working" cue shown at the foot of a streaming transcript:
/// three cyan dots pulsing in sequence beside a short status label
/// (`Thinking…`, `Responding…`, `Using read_file…`, a progress note). Driven by
/// `ConversationViewModel.activityStatus`. Shared by the Mac and iOS transcripts.
struct ThinkingIndicator: View {
    /// What grok is doing right now (`conversation.activityStatus`).
    var status: String
    /// Slightly smaller footprint for dense surfaces (e.g. the sidebar).
    var compact: Bool = false

    @State private var animating = false

    private var dot: CGFloat { compact ? 5 : 6 }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            HStack(spacing: compact ? 3 : 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: dot, height: dot)
                        .opacity(animating ? 1 : 0.25)
                        .scaleEffect(animating ? 1 : 0.6)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: animating
                        )
                }
            }
            .shadow(color: Theme.glow, radius: 3)

            if !status.isEmpty {
                Text(status)
                    .font(Theme.body(compact ? 11 : 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onAppear { animating = true }
    }
}
