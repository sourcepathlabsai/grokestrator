import Foundation

/// Parsed `when` spec for `trigger.schedule` (`design/11`).
public enum TriggerSchedule: Sendable, Equatable {
    /// Wake on `trigger.fire(event:)` — stored as `event:<name>` in `cronSpec`.
    case event(name: String)
    /// Fixed interval — `every 30m`, `every 1h`, `every 2d`.
    case interval(TimeInterval)

    /// Parse a `when` string from `trigger.schedule`.
    public static func parse(_ spec: String) -> TriggerSchedule? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("event:") {
            let name = String(trimmed.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .event(name: name)
        }
        if let interval = parseInterval(lower) {
            return .interval(interval)
        }
        return nil
    }

    /// Canonical storage form in `ScheduledTrigger.cronSpec`.
    public var cronSpec: String {
        switch self {
        case .event(let name): return "event:\(name)"
        case .interval(let seconds):
            if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
                return "every \(Int(seconds / 86_400))d"
            }
            if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
                return "every \(Int(seconds / 3_600))h"
            }
            if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
                return "every \(Int(seconds / 60))m"
            }
            return "every \(Int(seconds))s"
        }
    }

    public static func parseInterval(_ spec: String) -> TimeInterval? {
        let parts = spec.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "every", let n = Int(parts[1].filter(\.isNumber)), n > 0 else {
            return nil
        }
        let unit = parts[1].filter { !$0.isNumber }.lowercased()
        switch unit {
        case "s", "sec", "secs", "second", "seconds": return TimeInterval(n)
        case "m", "min", "mins", "minute", "minutes": return TimeInterval(n * 60)
        case "h", "hr", "hrs", "hour", "hours": return TimeInterval(n * 3_600)
        case "d", "day", "days": return TimeInterval(n * 86_400)
        default: return nil
        }
    }
}