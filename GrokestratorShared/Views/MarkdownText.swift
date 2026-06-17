import SwiftUI

/// Renders an assistant message as nicely-formatted Markdown — VS Code-preview
/// style: headings, bold/italic, inline `code`, fenced code blocks, bullet and
/// numbered lists, blockquotes, links, and horizontal rules. Block structure is
/// parsed here (line-based); inline spans inside each block are handled by
/// `AttributedString(markdown:)`, so this stays dependency-free and works
/// identically on macOS and iOS.
///
/// Streaming-safe: an unterminated code fence (mid-stream) renders as a code
/// block to the end of the text, and partial inline syntax falls back to literal
/// text rather than failing.
struct MarkdownText: View {
    let text: String
    /// Body point size; headings/code derive from it. Mac and iOS both pass 14.
    var baseSize: CGFloat = 14

    init(_ text: String, baseSize: CGFloat = 14) {
        self.text = text
        self.baseSize = baseSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .tint(Theme.accent)   // link color
    }

    // MARK: - Block model (shared parser — see `MarkdownParsing`)

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    // MARK: - Rendering

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(Theme.display(headingSize(level), level <= 2 ? .bold : .semibold))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 2 : 0)

        case .paragraph(let text):
            inlineText(text)
                .font(Theme.body(baseSize))
                .foregroundStyle(Theme.textBody)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(Theme.body(baseSize)).foregroundStyle(Theme.accent)
                        inlineText(item)
                            .font(Theme.body(baseSize))
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(Theme.body(baseSize))
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                        inlineText(item)
                            .font(Theme.body(baseSize))
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)

        case .quote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineText(line)
                            .font(Theme.body(baseSize))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .textSelection(.enabled)

        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(Theme.mono(baseSize - 3))
                        .foregroundStyle(Theme.textFaint)
                }
                Text(content)
                    .font(Theme.mono(baseSize - 1))
                    .foregroundStyle(Theme.textBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusXs))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusXs).strokeBorder(Theme.border))

        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 7
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }

    /// Builds a `Text` from a single block's inline Markdown. Code spans get a
    /// cyan monospaced treatment; the rest (bold/italic/strikethrough/links) is
    /// handled by `AttributedString`. Falls back to literal text on any failure.
    ///
    /// The parsed result is **memoized**: the macOS sticky-scroll re-hosts the
    /// whole transcript on each streaming refresh, which re-evaluates every
    /// on-screen `MarkdownText` body. Without this cache, every finalized message
    /// re-ran `AttributedString(markdown:)` ~20×/s during a live turn — the second
    /// half of the long-output beach-ball. A cache hit is just a dictionary lookup.
    private func inlineText(_ s: String) -> Text {
        let key = "\(baseSize)\u{1}\(s)" as NSString
        if let hit = Self.inlineCache.object(forKey: key) { return Text(hit.value) }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attr = try? AttributedString(markdown: s, options: options) else {
            return Text(s)
        }
        for run in attr.runs where (run.inlinePresentationIntent ?? []).contains(.code) {
            attr[run.range].font = .system(size: baseSize - 1, design: .monospaced)
            attr[run.range].foregroundColor = Theme.accent
        }
        Self.inlineCache.setObject(CachedAttributed(attr), forKey: key)
        return Text(attr)
    }

    /// Box for caching value-type `AttributedString` in an `NSCache`.
    private final class CachedAttributed {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Thread-safe; keyed by `baseSize` + source string. Bounded so a long session
    /// can't grow it without limit.
    private static let inlineCache: NSCache<NSString, CachedAttributed> = {
        let cache = NSCache<NSString, CachedAttributed>()
        cache.countLimit = 4000
        return cache
    }()

}
