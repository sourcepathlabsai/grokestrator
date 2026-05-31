import SwiftUI

/// A vertically-scrolling container that "sticks to the bottom" like a log
/// console or terminal.
///
/// The problem it solves: while grok streams a reply the transcript keeps
/// growing. If we always scrolled to the newest content, a user who had
/// scrolled up to re-read something would be yanked back to the bottom on every
/// delta — making it impossible to read. If we *never* scrolled, the live reply
/// would march off-screen.
///
/// The console rule: auto-scroll to the newest content **only while the user is
/// already at (or near) the bottom**. The instant they scroll up, new content
/// is appended silently; scrolling back down to the bottom re-arms the stick.
///
/// Bottom-proximity is measured with a coordinate-space + `GeometryReader`
/// trick (no iOS 18 `onScrollGeometryChange` — this targets macOS 14 / iOS 17):
/// the content's `maxY` in the scroll's own coordinate space, compared against
/// the viewport height, gives the distance from the bottom.
public struct StickyBottomScrollView<Content: View>: View {
    /// Bumps whenever new content streams in. Each change triggers a scroll —
    /// but only when the user is currently pinned to the bottom.
    private let tick: Int
    /// Bumps to *force* a scroll-to-bottom and re-pin, regardless of where the
    /// user had scrolled (e.g. they just sent a message — show it). Optional.
    private let pinToken: Int
    private let content: Content

    /// Whether the viewport is currently at/near the bottom (stick armed).
    @State private var isPinned = true
    @State private var viewportHeight: CGFloat = 0
    @State private var contentMaxY: CGFloat = 0

    /// Within this many points of the bottom still counts as "at the bottom".
    /// Generous enough that a single streaming delta (~one line) never trips the
    /// user from pinned to unpinned on its own.
    private let threshold: CGFloat = 80

    private let bottomID = "sticky-bottom-anchor"
    private let spaceName = "sticky-scroll-space"

    public init(tick: Int, pinToken: Int = 0, @ViewBuilder content: () -> Content) {
        self.tick = tick
        self.pinToken = pinToken
        self.content = content()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    // A zero-height anchor *after* everything (including any
                    // "Working…" indicator) so scrolling to the bottom reveals
                    // the true end of the transcript, not just the last entry.
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentMaxYKey.self,
                            value: geo.frame(in: .named(spaceName)).maxY
                        )
                    }
                )
            }
            .scrollContentBackground(.hidden)
            .coordinateSpace(name: spaceName)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ViewportHeightKey.self) { h in
                viewportHeight = h
                recomputePinned()
            }
            .onPreferenceChange(ContentMaxYKey.self) { y in
                contentMaxY = y
                recomputePinned()
            }
            .onChange(of: tick) {
                // Streaming growth: follow the bottom only if the user is there.
                guard isPinned else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: pinToken) {
                // Explicit request (message sent): always re-pin and jump down.
                isPinned = true
                withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onAppear {
                // Opening a transcript should land at the newest content.
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func recomputePinned() {
        guard viewportHeight > 0 else { return }
        // `contentMaxY` is the content's bottom edge expressed in the scroll
        // view's fixed coordinate space. When fully scrolled down it equals the
        // viewport height; scrolling up pushes it larger. The gap is how far the
        // user is from the bottom.
        let distanceFromBottom = contentMaxY - viewportHeight
        isPinned = distanceFromBottom <= threshold
    }
}

private struct ContentMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
