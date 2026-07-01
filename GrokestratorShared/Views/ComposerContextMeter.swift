import SwiftUI
import GrokestratorCore

/// Compact context-usage meter for the composer. Shows the running session total
/// (polled live during a turn via `ConversationViewModel.usage`) so context fill
/// is visible while composing — not only in the Instance Inspector.
struct ComposerContextMeter: View {
    let usage: SessionUsage?
    var isStreaming: Bool = false

    var body: some View {
        if let usage, usage.hasData {
            HStack(spacing: 8) {
                if let fraction = usage.fraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.surface)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColor(fraction))
                                .frame(width: max(2, geo.size.width * fraction))
                                .shadow(color: Theme.glow, radius: isStreaming ? 4 : 0)
                                .animation(.easeOut(duration: 0.25), value: usage.totalTokens)
                        }
                    }
                    .frame(width: 56, height: 4)
                }

                if let window = usage.contextWindow {
                    Text("\(TokenFormat.compact(usage.totalTokens)) / \(TokenFormat.compact(window))")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textBody)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: usage.totalTokens)
                    if let fraction = usage.fraction {
                        Text(String(format: "(%.0f%%)", fraction * 100))
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textFaint)
                    }
                } else {
                    Text(TokenFormat.compact(usage.totalTokens))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textBody)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: usage.totalTokens)
                }

                if isStreaming {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: Theme.glow, radius: 3)
                        .symbolEffect(.pulse, options: .repeating)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(usage))
        }
    }

    private func barColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .orange }
        return Theme.accent
    }

    private func accessibilityLabel(_ usage: SessionUsage) -> String {
        if let window = usage.contextWindow, let fraction = usage.fraction {
            return "Context \(TokenFormat.compact(usage.totalTokens)) of \(TokenFormat.compact(window)), \(Int(fraction * 100)) percent"
        }
        return "Context \(TokenFormat.compact(usage.totalTokens)) tokens"
    }
}

/// Shared token count formatting (`512000` → `"512K"`, `16435` → `"16.4K"`).
enum TokenFormat {
    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return n >= 100_000 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }
}