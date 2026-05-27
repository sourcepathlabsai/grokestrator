import Foundation

/// Detects quick-reply options in an assistant message — **only when confident**.
///
/// grok sends clarifying questions as free text (not structured), so we can't
/// reliably enumerate arbitrary choices. The rule (per product direction): if we
/// can't be certain, return nil and let the user type. v1 handles the clear
/// yes/no case; richer enumerations are intentionally left to typing.
enum QuickReplyDetector {
    static func detect(_ text: String) -> [String]? {
        guard text.contains("?") else { return nil }
        let lower = text.lowercased()

        // Explicit yes/no signal somewhere in the message: "yes or no", "yes/no", "(y/n)".
        let yesNoPatterns = [
            #"\byes\s*(?:or|/)\s*no\b"#,
            #"\bno\s*(?:or|/)\s*yes\b"#,
            #"\(\s*y\s*/\s*n\s*\)"#,
        ]
        if yesNoPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return ["Yes", "No"]
        }

        // Not confident → user types.
        return nil
    }
}
