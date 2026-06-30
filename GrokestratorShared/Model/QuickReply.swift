import Foundation

/// Extracts quick-reply options from an assistant message — **only when confident**.
///
/// Layers, highest-confidence first:
///  1. `[[CHOICES: a | b | c]]` block — the convention we ask grok to emit; reliable,
///     stripped from the displayed text. Handles any number of long options.
///  2. Explicit yes/no signal ("yes or no", "yes/no", "(y/n)").
///  3. Marked list — `(a)/a)/a./1./1)/-/•` items (≥2). Handles long options cleanly.
///  4. Delimited list — a `:`- or `( )`-delimited comma/"or" run (the delimiter strips
///     the interrogative lead, so options are clean).
///  5. Bounded binary "X or Y?" — single "or", no commas, short sides (catches "Python or Rust?").
///
/// Anything ambiguous → no options; the user types. Free text is always available regardless.
enum QuickReplyDetector {
    /// Returns the text to display (any `[[CHOICES]]` block removed) and the options ([] if none).
    static func analyze(_ text: String) -> (display: String, options: [String]) {
        if let block = choicesBlock(text) { return block }
        guard text.contains("?") else { return (text, []) }
        let opts = yesNo(text) ?? markedList(text) ?? delimitedList(text) ?? binaryOr(text)
        return (text, opts ?? [])
    }

    // MARK: - Layers

    private static func choicesBlock(_ text: String) -> (String, [String])? {
        guard let re = try? NSRegularExpression(pattern: #"\[\[\s*CHOICES\s*:\s*(.*?)\]\]"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let bodyRange = Range(m.range(at: 1), in: text),
              let fullRange = Range(m.range, in: text)
        else { return nil }
        let options = clean(String(text[bodyRange]).components(separatedBy: "|"))
        guard !options.isEmpty else { return nil }
        let display = text.replacingCharacters(in: fullRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (display, options)
    }

    private static func yesNo(_ text: String) -> [String]? {
        let lower = text.lowercased()
        let patterns = [#"\byes\s*(?:or|/)\s*no\b"#, #"\bno\s*(?:or|/)\s*yes\b"#, #"\(\s*y\s*/\s*n\s*\)"#]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil } ? ["Yes", "No"] : nil
    }

    private static func markedList(_ text: String) -> [String]? {
        let itemPattern = #"(?m)^\s*(?:\(?[a-zA-Z]\)|\(?\d+[.)]|[-*•])\s+(.+?)\s*$"#
        guard let re = try? NSRegularExpression(pattern: itemPattern) else { return nil }
        // Only consider list items near the last question mark (within ~200
        // chars). A list describing past work far before any "?" is descriptive,
        // not interrogative (e.g. "I made these changes: - X - Y. Any questions?").
        let lastQ = text.distance(from: text.startIndex, to: text.lastIndex(of: "?") ?? text.endIndex)
        var items: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text) {
                let itemStart = m.range.location
                if itemStart >= lastQ - 200 { items.append(String(text[r])) }
            }
        }
        let options = clean(items)
        return options.count >= 2 ? options : nil
    }

    private static func delimitedList(_ text: String) -> [String]? {
        // Prefer a parenthetical or the tail after the last colon — both strip the lead.
        var segment: String?
        if let re = try? NSRegularExpression(pattern: #"\(([^)]*(?:,|\bor\b)[^)]*)\)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            segment = String(text[r])
        } else if let colon = text.lastIndex(of: ":") {
            segment = String(text[text.index(after: colon)...])
        }
        guard let seg = segment else { return nil }
        // A colon-delimited list in a declarative sentence ("I used: X, Y, Z")
        // is not a question. Require a `?` somewhere near the segment.
        let hasQuestion = seg.contains("?") || {
            guard let segRange = text.range(of: seg) else { return false }
            let after = text[segRange.upperBound...]
            return after.contains("?")
        }()
        guard hasQuestion else { return nil }
        let raw = seg
            .replacingOccurrences(of: #"\bor\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: ",")
        let options = clean(raw)
        // Require ≥2 short-ish options; bail if any looks like a clause.
        guard options.count >= 2, options.allSatisfy({ wordCount($0) <= 6 }) else { return nil }
        return options
    }

    private static func binaryOr(_ text: String) -> [String]? {
        guard let q = text.split(whereSeparator: { $0 == "?" }).first.map(String.init) else { return nil }
        // Reject common rhetorical question patterns.
        let lower = q.lowercased()
        let rhetorical = ["do you have any", "is there anything", "do you need anything",
                          "would you like anything", "any other questions", "anything else"]
        if rhetorical.contains(where: { lower.contains($0) }) { return nil }
        guard !q.contains(","), let orRange = q.range(of: #"\bor\b"#, options: .regularExpression) else { return nil }
        // Exactly one "or"
        if q.range(of: #"\bor\b"#, options: .regularExpression, range: orRange.upperBound..<q.endIndex) != nil { return nil }
        let left = String(q[q.startIndex..<orRange.lowerBound])
        let right = String(q[orRange.upperBound...])
        guard let a = trailingPhrase(left), let b = clean([right]).first, wordCount(b) <= 4 else { return nil }
        return [a, b]
    }

    // MARK: - Helpers

    /// The trailing option phrase of the left side of an "or" — words from the end up to a "lead" word.
    private static func trailingPhrase(_ s: String) -> String? {
        let stoppers: Set<String> = ["should", "i", "you", "we", "do", "does", "did", "would", "will",
                                     "can", "shall", "use", "using", "pick", "choose", "prefer", "like",
                                     "want", "the", "a", "an", "to", "go", "with", "between", "either",
                                     "me", "my", "is", "are", "be", "it", "that", "this", "of", "for"]
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var tail: [String] = []
        for w in words.reversed() {
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if stoppers.contains(bare) { break }
            tail.insert(w, at: 0)
            if tail.count >= 4 { break }
        }
        let phrase = clean([tail.joined(separator: " ")]).first
        return (phrase?.isEmpty == false) ? phrase : nil
    }

    private static func clean(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let filler: Set<String> = ["", "e.g.", "i.e.", "etc.", "etc", "or", "and", "either"]
        for item in items {
            let t = item.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.?!\"'`*"))
            let key = t.lowercased()
            if t.isEmpty || filler.contains(key) || seen.contains(key) { continue }
            seen.insert(key); out.append(t)
            if out.count >= 6 { break }
        }
        return out
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}
