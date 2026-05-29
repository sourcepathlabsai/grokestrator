import SwiftUI
import AppKit

/// Branded "About Grokestrator" window — replaces macOS's stock about panel so
/// it matches the SourcePath look (dark navy + cyan glow, Space Grotesk / Inter).
/// Opened from the app menu via `CommandGroup(replacing: .appInfo)`.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            appIcon

            VStack(spacing: 4) {
                Text("Grokestrator")
                    .font(Theme.display(30, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Orchestrate your grok agents — anywhere.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }

            Text(Self.versionLine)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border))

            Divider().overlay(Theme.border).padding(.horizontal, 40)

            VStack(spacing: 6) {
                Text("A SourcePath Labs project")
                    .font(Theme.body(12, .medium))
                    .foregroundStyle(Theme.textBody)
                Text(Self.copyright)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(width: 380)
        .background(
            LinearGradient(colors: [Theme.bg, Theme.bgDeep],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 96, height: 96)
            .shadow(color: Theme.glow, radius: 24)
    }

    // MARK: - Bundle info

    /// "Version 0.1.0 (1)" — marketing version + build, read from Info.plist.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    private static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© SourcePath Labs"
    }
}
