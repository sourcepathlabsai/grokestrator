import SwiftUI

/// Shows `content` at its natural height, but becomes scrollable once that
/// height would exceed `maxHeight`. Used by the permission / question overlays:
/// grok can offer many wordy options, and a fixed overlay above the composer
/// would otherwise clip the top choices off-screen.
///
/// Unlike a bare `.frame(maxHeight:)` (which reserves the full height and
/// centers short content, leaving gaps), this measures the content and sizes the
/// container to `min(content, maxHeight)` — exact fit when it fits, capped +
/// scrolling when it doesn't.
struct ScrollableIfNeeded<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollableContentHeightKey.self, value: geo.size.height)
                    }
                )
        }
        // Before the first measurement, reserve the cap so nothing flashes at
        // zero height; afterwards size exactly to content up to the cap.
        .frame(height: min(measured == 0 ? maxHeight : measured, maxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ScrollableContentHeightKey.self) { measured = $0 }
    }
}

private struct ScrollableContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
