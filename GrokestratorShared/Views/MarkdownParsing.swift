import Foundation

/// Block-level Markdown model + parser, shared by the SwiftUI renderer
/// (`MarkdownText`) and the selectable attributed renderer
/// (`SelectableMarkdownText`). Line-based and dependency-free; inline spans inside
/// each block are handled by the renderer via `AttributedString(markdown:)`.
///
/// Streaming-safe: an unterminated code fence renders as a code block to the end of
/// the text, and partial inline syntax falls back to literal text.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case ordered([String])
    case quote([String])
    case code(language: String?, content: String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
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

    static func isRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        let chars = Set(t.replacingOccurrences(of: " ", with: ""))
        return chars.count == 1 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    static func heading(_ t: String) -> MarkdownBlock? {
        var level = 0
        for ch in t { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), t.count > level,
              t[t.index(t.startIndex, offsetBy: level)] == " " else { return nil }
        let body = String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: body)
    }

    static func isBullet(_ t: String) -> Bool {
        (t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ "))
    }
    static func bulletText(_ t: String) -> String {
        String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    static func isOrdered(_ t: String) -> Bool { orderedSplit(t) != nil }
    static func orderedText(_ t: String) -> String { orderedSplit(t) ?? t }
    /// `"12. foo"` → `"foo"`, else nil. Accepts `.` or `)` after the number.
    static func orderedSplit(_ t: String) -> String? {
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
