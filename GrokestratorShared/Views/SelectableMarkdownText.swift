import SwiftUI

/// Renders a message's Markdown into a **single read-only, selectable text view**
/// (`NSTextView` / `UITextView`), so the *whole* message — across paragraphs, code
/// blocks, lists — can be selected and copied with one drag + ⌘C. SwiftUI's `Text`
/// can't extend a selection across sibling views, which is why the per-block
/// `MarkdownText` only let you select one block at a time.
///
/// Styling (headings, bold/italic, inline + fenced code, lists, quotes, links) is
/// carried as attributes on the string, so it stays visually close to `MarkdownText`
/// while being natively selectable. Block parsing is shared (`MarkdownParser`).
struct SelectableMarkdownText: View {
    let text: String
    var baseSize: CGFloat = 14

    init(_ text: String, baseSize: CGFloat = 14) {
        self.text = text
        self.baseSize = baseSize
    }

    var body: some View {
        SelectableTextRepresentable(text: text, baseSize: baseSize)
            .tint(Theme.accent)
    }
}

// MARK: - Caches (streaming hot path)

// The transcript re-evaluates visible rows on every streaming tick (~20×/s). Without
// caching, each on-screen message re-ran `AttributedString(markdown:)` AND a full
// `ensureLayout` in `sizeThatFits` — and the per-measure frame mutation fed a layout
// loop that blanked the transcript for the whole stream. Both are now keyed by
// content (+ width for height) so a stable message is an O(1) lookup. NSCache is
// internally thread-safe; `nonisolated(unsafe)` just opts out of the global-actor check.
nonisolated(unsafe) private let mdAttributedCache: NSCache<NSString, NSAttributedString> = {
    let c = NSCache<NSString, NSAttributedString>(); c.countLimit = 2000; return c
}()
nonisolated(unsafe) private let mdHeightCache: NSCache<NSString, NSNumber> = {
    let c = NSCache<NSString, NSNumber>(); c.countLimit = 4000; return c
}()

private func cachedHeight(_ text: String, baseSize: CGFloat, width: CGFloat) -> CGFloat? {
    mdHeightCache.object(forKey: heightKey(text, baseSize, width)).map { CGFloat($0.doubleValue) }
}
private func storeHeight(_ h: CGFloat, text: String, baseSize: CGFloat, width: CGFloat) {
    mdHeightCache.setObject(NSNumber(value: Double(h)), forKey: heightKey(text, baseSize, width))
}
private func heightKey(_ text: String, _ baseSize: CGFloat, _ width: CGFloat) -> NSString {
    "\(baseSize)\u{1}\(Int(width.rounded()))\u{1}\(text)" as NSString
}

// MARK: - Attributed-string builder (shared; uses platform font/color helpers)

private func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
    switch level {
    case 1: return base + 7
    case 2: return base + 4
    case 3: return base + 2
    default: return base + 1
    }
}

/// Build the full attributed string for a message. Blocks are separated by a blank
/// line; inline spans inside each block come from `AttributedString(markdown:)`.
func makeMarkdownAttributed(_ text: String, baseSize: CGFloat) -> NSAttributedString {
    let cacheKey = "\(baseSize)\u{1}\(text)" as NSString
    if let hit = mdAttributedCache.object(forKey: cacheKey) { return hit }

    let out = NSMutableAttributedString()
    let body = themeColor(Theme.textBody)
    let nl = { (s: String) in NSAttributedString(string: s, attributes: [.font: baseFont(baseSize), .foregroundColor: body]) }

    for (idx, block) in MarkdownParser.parse(text).enumerated() {
        if idx > 0 { out.append(nl("\n\n")) }
        switch block {
        case .heading(let level, let t):
            appendInline(t, font: headingFont(headingSize(level, base: baseSize)),
                         color: themeColor(Theme.textPrimary), into: out)

        case .paragraph(let t):
            appendInline(t, font: baseFont(baseSize), color: body, into: out)

        case .bullets(let items):
            for (j, item) in items.enumerated() {
                if j > 0 { out.append(nl("\n")) }
                out.append(NSAttributedString(string: "•  ", attributes: [
                    .font: baseFont(baseSize), .foregroundColor: themeColor(Theme.accent)]))
                appendInline(item, font: baseFont(baseSize), color: body, into: out)
            }

        case .ordered(let items):
            for (j, item) in items.enumerated() {
                if j > 0 { out.append(nl("\n")) }
                out.append(NSAttributedString(string: "\(j + 1).  ", attributes: [
                    .font: baseFont(baseSize), .foregroundColor: themeColor(Theme.accent)]))
                appendInline(item, font: baseFont(baseSize), color: body, into: out)
            }

        case .quote(let lines):
            for (j, line) in lines.enumerated() {
                if j > 0 { out.append(nl("\n")) }
                appendInline(line, font: italicFont(baseFont(baseSize)),
                             color: themeColor(Theme.textMuted), into: out)
            }

        case .code(let language, let content):
            let start = out.length
            if let language, !language.isEmpty {
                out.append(NSAttributedString(string: language.lowercased() + "\n", attributes: [
                    .font: monoFont(baseSize - 3), .foregroundColor: themeColor(Theme.textFaint)]))
            }
            out.append(NSAttributedString(string: content, attributes: [
                .font: monoFont(baseSize - 1), .foregroundColor: body]))
            out.addAttribute(.backgroundColor, value: themeColor(Theme.surface),
                             range: NSRange(location: start, length: out.length - start))

        case .rule:
            out.append(NSAttributedString(string: "──────────", attributes: [
                .font: baseFont(baseSize), .foregroundColor: themeColor(Theme.border)]))
        }
    }

    let para = NSMutableParagraphStyle()
    para.lineSpacing = 2
    out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
    mdAttributedCache.setObject(out, forKey: cacheKey)
    return out
}

/// Append one block's inline Markdown (bold/italic/`code`/links) as styled runs.
private func appendInline(_ s: String, font: PlatformFont, color: PlatformColor, into out: NSMutableAttributedString) {
    let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard let attr = try? AttributedString(markdown: s, options: options) else {
        out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        return
    }
    for run in attr.runs {
        let piece = String(attr[run.range].characters)
        var f = font
        var c = color
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.stronglyEmphasized) { f = boldFont(f) }
        if intent.contains(.emphasized) { f = italicFont(f) }
        if intent.contains(.code) { f = monoFont(f.pointSize); c = themeColor(Theme.accent) }
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
        if let link = run.link {
            attrs[.link] = link
            attrs[.foregroundColor] = themeColor(Theme.accent)
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        out.append(NSAttributedString(string: piece, attributes: attrs))
    }
}

// MARK: - macOS

#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor

private func themeColor(_ c: Color) -> NSColor { NSColor(c) }
private func baseFont(_ s: CGFloat) -> NSFont { NSFont(name: "Inter", size: s) ?? .systemFont(ofSize: s) }
private func headingFont(_ s: CGFloat) -> NSFont { boldFont(baseFont(s)) }
private func monoFont(_ s: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: s, weight: .regular) }
private func boldFont(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
private func italicFont(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

private struct SelectableTextRepresentable: NSViewRepresentable {
    let text: String
    let baseSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Mirrors the proven resizable-NSTextView recipe in `ComposerTextView`, but
    // read-only + rich text. The non-scrolling scroll view gives the (vertically
    // resizable) text view a stable host so it doesn't collapse to zero height.
    func makeNSView(context: Context) -> NSScrollView {
        let contentSize = NSSize(width: 200, height: 40)
        let tv = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.linkTextAttributes = [.foregroundColor: NSColor(Theme.accent), .cursor: NSCursor.pointingHand]
        if let container = tv.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        }

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        apply(to: tv, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        apply(to: tv, context: context)
    }

    private func apply(to tv: NSTextView, context: Context) {
        guard context.coordinator.text != text || context.coordinator.size != baseSize else { return }
        context.coordinator.text = text
        context.coordinator.size = baseSize
        tv.textStorage?.setAttributedString(makeMarkdownAttributed(text, baseSize: baseSize))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? scroll.frame.width
        guard width.isFinite, width > 0, width < 100_000 else { return nil }
        // Cache hit → no frame mutation / no relayout. This is what keeps a streaming
        // transcript from thrashing: stable messages just return their known height.
        if let h = cachedHeight(text, baseSize: baseSize, width: width) {
            return CGSize(width: width, height: h)
        }
        guard let tv = scroll.documentView as? NSTextView,
              let container = tv.textContainer, let layout = tv.layoutManager else { return nil }
        tv.frame.size.width = width
        container.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let h = ceil(layout.usedRect(for: container).height)
        storeHeight(h, text: text, baseSize: baseSize, width: width)
        return CGSize(width: width, height: h)
    }

    final class Coordinator { var text: String?; var size: CGFloat? }
}

#elseif os(iOS)
import UIKit
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor

private func themeColor(_ c: Color) -> UIColor { UIColor(c) }
private func baseFont(_ s: CGFloat) -> UIFont { UIFont(name: "Inter", size: s) ?? .systemFont(ofSize: s) }
private func headingFont(_ s: CGFloat) -> UIFont { boldFont(baseFont(s)) }
private func monoFont(_ s: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: s, weight: .regular) }
private func boldFont(_ f: UIFont) -> UIFont { f.withTraits(.traitBold) }
private func italicFont(_ f: UIFont) -> UIFont { f.withTraits(.traitItalic) }

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}

private struct SelectableTextRepresentable: UIViewRepresentable {
    let text: String
    let baseSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.tintColor = UIColor(Theme.accent)
        tv.linkTextAttributes = [.foregroundColor: UIColor(Theme.accent)]
        apply(to: tv, context: context)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) { apply(to: tv, context: context) }

    private func apply(to tv: UITextView, context: Context) {
        guard context.coordinator.text != text || context.coordinator.size != baseSize else { return }
        context.coordinator.text = text
        context.coordinator.size = baseSize
        tv.attributedText = makeMarkdownAttributed(text, baseSize: baseSize)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? tv.frame.width
        guard width.isFinite, width > 0, width < 100_000 else { return nil }
        if let h = cachedHeight(text, baseSize: baseSize, width: width) {
            return CGSize(width: width, height: h)
        }
        let fit = tv.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let h = ceil(fit.height)
        storeHeight(h, text: text, baseSize: baseSize, width: width)
        return CGSize(width: width, height: h)
    }

    final class Coordinator { var text: String?; var size: CGFloat? }
}
#endif
