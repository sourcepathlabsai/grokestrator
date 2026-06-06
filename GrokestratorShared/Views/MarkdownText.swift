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

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case ordered([String])
        case quote([String])
        case code(language: String?, content: String)
        case rule
    }

    private var blocks: [Block] { Self.parse(text) }

    // MARK: - Rendering

    @ViewBuilder
    private func view(for block: Block) -> some View {
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

    // MARK: - Parsing

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func isFence(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("~~~") { return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            return nil
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block — collect to the closing fence OR end of text
            // (so a still-streaming block renders as code).
            if let lang = isFence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count, isFence(lines[i]) == nil {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // consume closing fence
                blocks.append(.code(language: lang.isEmpty ? nil : lang,
                                    content: body.joined(separator: "\n")))
                continue
            }

            // Blank line — block separator.
            if trimmed.isEmpty { i += 1; continue }

            // Horizontal rule: 3+ of - * _ , nothing else.
            if isRule(trimmed) { blocks.append(.rule); i += 1; continue }

            // ATX heading: 1–6 leading '#', then a space.
            if let h = heading(trimmed) { blocks.append(h); i += 1; continue }

            // Blockquote run.
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote)); continue
            }

            // Unordered list run.
            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(bulletText(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.bullets(items)); continue
            }

            // Ordered list run.
            if isOrdered(trimmed) {
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(orderedText(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.ordered(items)); continue
            }

            // Paragraph — gather consecutive "plain" lines until a blank line or
            // a line that starts a different block.
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isFence(lines[i]) != nil || isRule(t) || heading(t) != nil
                    || t.hasPrefix(">") || isBullet(t) || isOrdered(t) { break }
                para.append(t); i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
        }
        return blocks
    }

    private static func isRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        let chars = Set(t.replacingOccurrences(of: " ", with: ""))
        return chars.count == 1 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    private static func heading(_ t: String) -> Block? {
        var level = 0
        for ch in t { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), t.count > level,
              t[t.index(t.startIndex, offsetBy: level)] == " " else { return nil }
        let body = String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: body)
    }

    private static func isBullet(_ t: String) -> Bool {
        (t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ "))
    }
    private static func bulletText(_ t: String) -> String {
        String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isOrdered(_ t: String) -> Bool { orderedSplit(t) != nil }
    private static func orderedText(_ t: String) -> String { orderedSplit(t) ?? t }
    /// `"12. foo"` → `"foo"`, else nil. Accepts `.` or `)` after the number.
    private static func orderedSplit(_ t: String) -> String? {
        var digits = 0
        for ch in t { if ch.isNumber { digits += 1 } else { break } }
        guard digits > 0, t.count > digits + 1 else { return nil }
        let sep = t[t.index(t.startIndex, offsetBy: digits)]
        guard sep == "." || sep == ")" else { return nil }
        let after = t.index(t.startIndex, offsetBy: digits + 1)
        guard after < t.endIndex, t[after] == " " else { return nil }
        return String(t[t.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }
}
