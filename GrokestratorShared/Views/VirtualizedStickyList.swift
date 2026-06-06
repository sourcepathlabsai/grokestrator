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
                guard isPinned else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            // Forced re-pin (user sent, or switched Connection).
            .onChange(of: pinToken) {
                isPinned = true
                withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            // Land at the bottom on first appearance.
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }
}
