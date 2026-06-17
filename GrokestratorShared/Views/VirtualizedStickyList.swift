import SwiftUI

/// A vertically-scrolling, **virtualized** list that sticks to the bottom like a
/// console — built for a transcript that can grow huge and stream live.
///
/// Cost is bounded by the **viewport, not the total item count**: the
/// `LazyVStack` materializes only the rows near the screen (verified: ~12 row
/// bodies built for a 1000-row list), and a streaming update re-renders only the
/// one row whose content changed. Replaces the old `NSHostingView`-of-the-whole-
/// transcript scroller, which force-laid-out every row on every delta.
///
/// Sticky-bottom rule: auto-follow the newest content only while the user is
/// already at the bottom (precise, synchronous detection via
/// `onScrollGeometryChange`). Scroll up to read and new content appends silently;
/// scroll back down to re-arm.
struct VirtualizedStickyList<Item: Identifiable, RowContent: View>: View where Item.ID: Hashable {
    /// The rows, in order.
    let items: [Item]
    /// Bumps on every content mutation — a chance to follow the bottom.
    let tick: Int
    /// Bumps to *force* a scroll-to-bottom and re-arm (send / Connection switch).
    var pinToken: Int = 0
    /// Vertical gap between rows.
    var rowSpacing: CGFloat = 12
    /// Uniform inset around the content.
    var contentInset: CGFloat = 16
    @ViewBuilder let row: (Item) -> RowContent

    /// True while the viewport is at (or within `threshold` of) the bottom.
    @State private var isPinned = true

    /// True once we've landed at the bottom for the *current* content. Reset on a
    /// forced re-pin (Connection switch) so the incoming transcript re-lands.
    @State private var didInitialScroll = false

    /// The in-flight "settle" burst, cancelled when a newer one supersedes it.
    @State private var settleTask: Task<Void, Never>?

    /// Within this many points of the bottom still counts as "at the bottom".
    private let threshold: CGFloat = 44
    private let bottomID = "vsl-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(items) { item in
                        row(item).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Zero-height bottom anchor we scroll to when following.
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(contentInset)
            }
            // Precise, synchronous "am I at the bottom?" — the signal the old
            // macOS NSScrollView hack existed to provide. Updates as the user
            // scrolls and as content grows.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - threshold
            } action: { _, atBottom in
                isPinned = atBottom
            }
            // Content changed: follow the bottom only if we were already there.
            .onChange(of: tick) {
                // First content for this connection arrived after we appeared
                // (history replays asynchronously): land on the newest entry.
                if !didInitialScroll, !items.isEmpty {
                    settleToBottom(proxy)
                    return
                }
                guard isPinned else { return }
                // Re-issue across a short settle window, not a single shot: a turn
                // that *finalizes* re-renders its message from plain streaming text
                // into formatted Markdown and grows taller **after** this tick, so a
                // lone scrollTo lands short and strands the user above the new bottom.
                // Heights are cached, so the burst rests on a stable bottom (no jink).
                settleToBottom(proxy)
            }
            // Forced re-pin (user sent, or switched Connection): re-land at the
            // bottom even though the incoming transcript's rows realize late.
            .onChange(of: pinToken) {
                didInitialScroll = false
                settleToBottom(proxy)
            }
            // Land at the bottom on first appearance.
            .onAppear { settleToBottom(proxy) }
        }
    }

    /// Drive the viewport to the bottom and *keep* it there across a short
    /// settling window. A single `scrollTo` is not enough for the transcript:
    /// the rows render Markdown whose true height is known only after async
    /// layout, so the first scroll lands against under-estimated heights and the
    /// rows below then grow and push the real bottom past us — leaving the user
    /// stranded mid-transcript (worse the more content there is). Re-issuing the
    /// scroll as heights settle catches up; we force it regardless of the
    /// transient `isPinned` flips that row-growth itself triggers. Verified in a
    /// simulator harness: a single shot stalls ~16 rows short of the end; the
    /// burst lands exactly on the last entry.
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        didInitialScroll = true
        isPinned = true
        proxy.scrollTo(bottomID, anchor: .bottom)
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            for ms in [16, 50, 120, 250, 450] {
                try? await Task.sleep(for: .milliseconds(ms))
                if Task.isCancelled { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            isPinned = true
        }
    }
}
