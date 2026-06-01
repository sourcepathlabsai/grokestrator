import SwiftUI

/// A vertically-scrolling container that "sticks to the bottom" like a log
/// console or terminal.
///
/// The console rule: auto-scroll to the newest content **only while the user is
/// already at (or near) the bottom**. The instant they scroll up to re-read
/// something, new content is appended silently; scrolling back to the bottom
/// re-arms the stick.
///
/// macOS implementation note: we do NOT use a SwiftUI `ScrollView` +
/// `GeometryReader` to detect bottom-proximity. On macOS 14 that geometry does
/// not update reliably while the user scrolls, so the "is the user at the
/// bottom?" flag goes stale and every streaming delta yanks the viewport back
/// down. Instead we host the content in a real `NSScrollView` and read the clip
/// view's position **synchronously, right before the content grows** — the only
/// race-free way to know where the user actually is.
public struct StickyBottomScrollView<Content: View>: View {
    /// Bumps whenever new content streams in. Each change is a chance to follow
    /// the bottom — but only when the user is currently at the bottom.
    private let tick: Int
    /// Bumps to *force* a scroll-to-bottom and re-arm (e.g. the user sent a
    /// message, or switched Connections). Optional.
    private let pinToken: Int
    private let content: Content

    public init(tick: Int, pinToken: Int = 0, @ViewBuilder content: () -> Content) {
        self.tick = tick
        self.pinToken = pinToken
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
        MacStickyScroll(tick: tick, pinToken: pinToken, content: content)
        #else
        LegacyStickyScroll(tick: tick, pinToken: pinToken) { content }
        #endif
    }
}

#if os(macOS)
import AppKit

/// NSScrollView-backed sticky scroller. Hosts the SwiftUI `content` in an
/// `NSHostingView` and decides whether to follow the bottom by reading the real
/// scroll position before each content update.
private struct MacStickyScroll<Content: View>: NSViewRepresentable {
    let tick: Int
    let pinToken: Int
    let content: Content

    /// Within this many points of the bottom still counts as "at the bottom".
    private let threshold: CGFloat = 40

    func makeCoordinator() -> Coordinator { Coordinator(pinToken: pinToken) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        NSLayoutConstraint.activate([
            // Pin top + sides to the clip view → fixed width (content wraps),
            // anchored to the top. No bottom pin: the hosting view's intrinsic
            // content height drives the scrollable area, so it grows and scrolls.
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        context.coordinator.hosting = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        // Read the user's ACTUAL position before the content grows. This is the
        // race-free signal: if they've scrolled up, we leave them alone.
        let wasAtBottom = coord.isAtBottom(scrollView, threshold: threshold)

        coord.hosting?.rootView = AnyView(content)
        coord.hosting?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let forced = coord.lastPinToken != pinToken
        coord.lastPinToken = pinToken

        if !coord.didInitialScroll || forced || wasAtBottom {
            coord.didInitialScroll = true
            // Defer to the next main-actor turn so the documentView height is
            // final after the content update. `Task { @MainActor }` (not
            // DispatchQueue) keeps the AppKit access on the main actor, which
            // Swift 6 requires for NSScrollView's main-actor-isolated members.
            Task { @MainActor in coord.scrollToBottom(scrollView) }
        }
    }

    /// Main-actor isolated: every method touches main-actor-isolated AppKit
    /// state (NSScrollView/NSClipView), and all call sites are the
    /// representable's own main-actor methods.
    @MainActor
    final class Coordinator {
        var hosting: NSHostingView<AnyView>?
        var lastPinToken: Int
        var didInitialScroll = false

        init(pinToken: Int) { self.lastPinToken = pinToken }

        /// NSHostingView is flipped (top-left origin), so the clip view's
        /// `bounds.maxY` is the bottom edge of the visible region in document
        /// space; compare it to the document's full height.
        func isAtBottom(_ sv: NSScrollView, threshold: CGFloat) -> Bool {
            guard let doc = sv.documentView else { return true }
            let docHeight = doc.bounds.height
            let visibleMaxY = sv.contentView.bounds.maxY
            // Nothing to scroll yet → treat as at the bottom (keep following).
            guard docHeight > sv.contentView.bounds.height else { return true }
            return docHeight - visibleMaxY <= threshold
        }

        func scrollToBottom(_ sv: NSScrollView) {
            guard let doc = sv.documentView else { return }
            let y = max(0, doc.bounds.height - sv.contentView.bounds.height)
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }
}
#endif

/// SwiftUI fallback used on iOS, where UIKit's scroll geometry is reliable
/// enough for the `GeometryReader` approach.
private struct LegacyStickyScroll<Content: View>: View {
    let tick: Int
    let pinToken: Int
    @ViewBuilder let content: () -> Content

    @State private var isPinned = true
    @State private var viewportHeight: CGFloat = 0
    @State private var contentMaxY: CGFloat = 0

    private let threshold: CGFloat = 80
    private let bottomID = "sticky-bottom-anchor"
    private let spaceName = "sticky-scroll-space"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(bottomID)
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
                viewportHeight = h; recomputePinned()
            }
            .onPreferenceChange(ContentMaxYKey.self) { y in
                contentMaxY = y; recomputePinned()
            }
            .onChange(of: tick) {
                guard isPinned else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: pinToken) {
                isPinned = true
                withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private func recomputePinned() {
        guard viewportHeight > 0 else { return }
        isPinned = (contentMaxY - viewportHeight) <= threshold
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
