import SwiftUI

/// Keys the composer can hand back to its host (used on macOS to drive the
/// slash-command popup: arrow to move the highlight, Return to pick, Escape to
/// dismiss). The host returns `true` if it consumed the key; otherwise the text
/// view handles it normally (Return → submit, arrows → move the caret).
public enum ComposerKey {
    case up, down, returnKey, escape
}

/// A multi-line message composer backed by a real `NSTextView`/`UITextView`.
///
/// Why not `TextField(axis: .vertical)`? That control caches its line-break
/// layout in its field editor and does **not** re-wrap already-entered text when
/// only its container width changes — so when the inspector panel opens and the
/// composer shrinks, a long in-progress line runs past the new margin. A real
/// text view's text container tracks its width (`widthTracksTextView`) and
/// reflows on every width change, which is exactly the requirement here.
///
/// Behaviour preserved from the old `TextField`:
/// - grows from 1 to `maxLines` lines, then scrolls;
/// - Return submits, Shift/Option+Return inserts a newline;
/// - a placeholder shows while empty;
/// - programmatic focus via the `isFocused` binding;
/// - (macOS) arrow/Return/Escape are offered to `onKey` first for the popup.
public struct ComposerTextView: View {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    var maxLines: Int = 6
    let onSubmit: () -> Void
    var onKey: ((ComposerKey) -> Bool)? = nil
    @Binding var isFocused: Bool

    public init(
        text: Binding<String>,
        placeholder: String,
        fontSize: CGFloat,
        maxLines: Int = 6,
        isFocused: Binding<Bool>,
        onSubmit: @escaping () -> Void,
        onKey: ((ComposerKey) -> Bool)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.maxLines = maxLines
        self._isFocused = isFocused
        self.onSubmit = onSubmit
        self.onKey = onKey
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Representable(
                text: $text,
                fontSize: fontSize,
                maxLines: maxLines,
                isFocused: $isFocused,
                onSubmit: onSubmit,
                onKey: onKey
            )
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.body(fontSize))
                    .foregroundStyle(Theme.textFaint)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Platform fonts/colors

private func composerFont(_ size: CGFloat) -> PlatformFont {
    // "Inter" is registered process-wide at launch (Theme.registerFonts).
    PlatformFont(name: "Inter", size: size) ?? PlatformFont.systemFont(ofSize: size)
}

#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
private let composerTextColor = NSColor(Theme.textBody)

// MARK: macOS representable

private struct Representable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let maxLines: Int
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onKey: ((ComposerKey) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Apple's resizable-NSTextView recipe. The min/max size + container
        // config is mandatory: without it the (vertically resizable) text view
        // collapses to zero height inside the scroll view, leaving nothing to
        // click — hence no caret.
        let contentSize = NSSize(width: 200, height: 40)
        let textView = ComposerNSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.delegate = context.coordinator
        textView.font = composerFont(fontSize)
        textView.textColor = composerTextColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.string = text
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.onSubmit = onSubmit
        textView.onKey = onKey

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onKey = onKey
        if textView.string != text {
            textView.string = text
        }
        if textView.font?.pointSize != fontSize {
            textView.font = composerFont(fontSize)
        }
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? ComposerNSTextView,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }
        // SwiftUI probes layout with `.infinity` / huge / unspecified widths;
        // forwarding those into the text view's frame triggers "Invalid view
        // geometry: width is infinity/too large". Only measure for a real,
        // finite, bounded width; otherwise defer to default sizing.
        let width = proposal.width ?? scroll.frame.width
        guard width.isFinite, width > 0, width < 100_000 else { return nil }
        // Re-measure at the proposed width → text reflows, height follows. The text
        // view's width drives the (width-tracking) container, so set the frame first,
        // then lay out — but SAVE/RESTORE around it: SwiftUI probes this with several
        // candidate widths (including a transient narrow one when a sibling like the
        // slash-command popup is inserted), and leaving the container at a probe width
        // makes the live prompt wrap at a few characters until the next wide layout.
        // A measurement must not mutate persistent state.
        let savedWidth = textView.frame.size.width
        let savedContainer = container.containerSize
        defer {
            textView.frame.size.width = savedWidth
            container.containerSize = savedContainer
        }
        textView.frame.size.width = width
        container.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let line = textView.font?.boundingRectForFont.height ?? fontSize * 1.3
        let maxHeight = ceil(line * CGFloat(maxLines))
        let height = min(max(ceil(used), ceil(line)), maxHeight)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Representable
        weak var textView: ComposerNSTextView?
        init(_ parent: Representable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true }
        }
        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onKey: ((ComposerKey) -> Bool)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift { super.insertNewline(nil); return }
            if onKey?(.returnKey) == true { return }   // popup consumed Return
            onSubmit?()
            return
        case #selector(moveUp(_:)):
            if onKey?(.up) == true { return }
        case #selector(moveDown(_:)):
            if onKey?(.down) == true { return }
        case #selector(cancelOperation(_:)):
            if onKey?(.escape) == true { return }
        default:
            break
        }
        super.doCommand(by: selector)
    }
}

#elseif os(iOS)
import UIKit
private typealias PlatformFont = UIFont
private let composerTextColor = UIColor(Theme.textBody)

// MARK: iOS representable

private struct Representable: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let maxLines: Int
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onKey: ((ComposerKey) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = composerFont(fontSize)
        textView.textColor = composerTextColor
        textView.tintColor = UIColor(Theme.accent)
        textView.text = text
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false          // grow until capped, then scroll
        textView.returnKeyType = .send
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text { textView.text = text }
        if textView.font?.pointSize != fontSize { textView.font = composerFont(fontSize) }
        if isFocused, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? textView.frame.width
        guard width.isFinite, width > 0, width < 100_000 else { return nil }
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = textView.font?.lineHeight ?? fontSize * 1.3
        let maxHeight = ceil(line * CGFloat(maxLines))
        let height = min(max(ceil(fitting.height), ceil(line)), maxHeight)
        // Once content exceeds the cap, let the text view scroll internally.
        textView.isScrollEnabled = fitting.height > maxHeight
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: Representable
        init(_ parent: Representable) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}
#endif
