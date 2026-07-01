import Foundation

// MARK: - Detectors — where the rubber hits the road
//
// A detector is, physically, a function `(Action, Context) → [Finding]`. Two
// verdict grades (design/13): `definitive` detectors DECIDE (a precise, deterministic
// check — the clever ~10–20%); `suspect` detectors FLAG (high-recall regex/heuristic
// — the dumb ~80%) and defer to a grounded judge (shadow v0: escalate).
//
// The slice's two detectors also demonstrate the boundary-fidelity refinement we
// discovered: `minimumFidelity` declares the structure a detector needs, and it
// ABSTAINS below it (never fail-open — fail-closed-on-unknown covers the gap).
//  • PathEscapeDetector — precise/definitive, needs `.structured` args ⇒ runs on API
//    actions, abstains on ACP permission actions.
//  • DestructiveShellDetector — recall/suspect, needs only `payloadText` ⇒ runs on
//    BOTH boundaries (ACP gives us the command string for Bash-like calls).

public protocol Detector: Sendable {
    /// Stable id; invariants reference a detector by this.
    var id: String { get }
    /// The invariant this detector enforces (the membrane link back to prose).
    var invariantID: String { get }
    /// The least fidelity this detector can operate on. Below it, `examine` is not
    /// called and the detector abstains.
    var minimumFidelity: ProposedAction.Fidelity { get }
    func examine(_ action: ProposedAction) -> [Finding]
}

/// Precise / **definitive**. Resolves a file-path argument against the node's cwd; an
/// escape is a deterministic fact, so it decides (not a guess). Mirrors the ad-hoc
/// `resolved()` check already in `OpenAICompatSession` — here it is lifted into a
/// named, reusable invariant. Needs structured args ⇒ `.structured`.
public struct PathEscapeDetector: Detector {
    public static let detectorID = "DET-path-escape"
    public let id = PathEscapeDetector.detectorID
    public let invariantID = "INV-cwd-confinement"
    public let minimumFidelity: ProposedAction.Fidelity = .structured
    public init() {}

    public func examine(_ action: ProposedAction) -> [Finding] {
        guard let path = action.arguments?["path"], let cwd = action.context.workingDirectory
        else { return [] }
        let base = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                      : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        let resolved = url.standardizedFileURL.path
        let inside = resolved == base || resolved.hasPrefix(base + "/")
        guard !inside else { return [] }
        return [Finding(detector: id, invariantID: invariantID, confidence: .definitive,
                        severity: .high, trips: true,
                        note: "path '\(path)' resolves to '\(resolved)', outside cwd '\(base)'")]
    }
}

/// High-recall / **suspect**. Regex over the command/payload string for known
/// irreversible shapes. Recall by nature — it cannot know intent (a `rm -rf` in a
/// scratch dir may be fine), so it flags and defers. Needs only the payload string
/// ⇒ `.semiStructured`, so it works at the ACP boundary too.
public struct DestructiveShellDetector: Detector {
    public static let detectorID = "DET-destructive-shell"
    public let id = DestructiveShellDetector.detectorID
    public let invariantID = "INV-no-destructive-shell"
    public let minimumFidelity: ProposedAction.Fidelity = .semiStructured
    public init() {}

    /// Patterns for irreversible, system-unrecoverable shell effects. Deliberately a
    /// dumb-recall list (the threat-DB pattern): cheap to extend, expected to over-fire.
    private static let patterns: [(name: String, regex: String)] = [
        ("recursive force-remove", #"\brm\s+(-[a-zA-Z]*\s+)*-?[a-zA-Z]*[rf][a-zA-Z]*"#),
        ("filesystem format",      #"\bmkfs(\.\w+)?\b"#),
        ("raw disk write",         #"\bdd\b.*\bof=/dev/"#),
        ("redirect over device",   #">\s*/dev/(sd|disk|nvme)"#),
        ("git force-push",         #"\bgit\s+push\b.*(--force\b|-f\b)"#),
        ("fork bomb",              #":\(\)\s*\{\s*:\|:"#),
        ("recursive chmod root",   #"\bchmod\s+-R\s+.*\s+/\s*$"#),
    ]

    public func examine(_ action: ProposedAction) -> [Finding] {
        // The command may be in structured args (API: run_command.command) or only in
        // the payload string (ACP permission title / rawInput.command).
        let haystack = action.arguments?["command"] ?? action.payloadText ?? ""
        guard !haystack.isEmpty else { return [] }
        var findings: [Finding] = []
        for p in Self.patterns where haystack.range(of: p.regex, options: .regularExpression) != nil {
            findings.append(Finding(detector: id, invariantID: invariantID, confidence: .suspect,
                                    severity: .critical, trips: true,
                                    note: "matched '\(p.name)' in: \(haystack.prefix(120))"))
        }
        return findings
    }
}

/// High-recall / **suspect**. Flags actions that emit to parties outside the local
/// system — email, chat posts, webhooks, public API posts. Recall by nature (a `curl -d`
/// may be an internal health check), so it flags and defers to human review. Needs only
/// payload / semi-structured args ⇒ works at the ACP boundary too.
public struct ExternalCommsDetector: Detector {
    public static let detectorID = "DET-external-comms"
    public let id = ExternalCommsDetector.detectorID
    public let invariantID = "INV-external-comms-reviewed"
    public let minimumFidelity: ProposedAction.Fidelity = .semiStructured
    public init() {}

    /// Patterns for outbound communication shapes. Deliberately high-recall.
    private static let patterns: [(name: String, regex: String)] = [
        ("send email",          #"(?i)\bsend\s+email\b"#),
        ("smtp",                #"(?i)\bsmtp\b"#),
        ("sendmail",            #"(?i)\b(sendmail|mail\s+-s)\b"#),
        ("mailto",              #"(?i)mailto:"#),
        ("slack webhook",       #"(?i)hooks\.slack\.com"#),
        ("slack message",       #"(?i)\bslack\b.*\b(post|send|message)\b"#),
        ("discord webhook",     #"(?i)discord\.com/api/webhooks"#),
        ("curl POST",           #"(?i)\bcurl\b[^\n]*(-X\s+POST|--request\s+POST)\b"#),
        ("tweet",               #"(?i)\b(tweet|twurl)\b"#),
        ("gh comment",            #"(?i)\bgh\s+(issue|pr)\s+comment\b"#),
        ("post to channel",     #"(?i)\bpost\s+(to|message)\b"#),
        ("webhook",             #"(?i)\bwebhook\b"#),
        ("notify user",           #"(?i)\bnotify\s+user\b"#),
    ]

    private static let mcpToolPattern = #"(?i)(send|post|email|notify|tweet|slack|mail|message)"#

    public func examine(_ action: ProposedAction) -> [Finding] {
        let haystack = Self.haystack(for: action)
        guard !haystack.isEmpty else { return [] }
        var findings: [Finding] = []
        for p in Self.patterns where haystack.range(of: p.regex, options: .regularExpression) != nil {
            findings.append(Finding(detector: id, invariantID: invariantID, confidence: .suspect,
                                    severity: .high, trips: true,
                                    note: "matched '\(p.name)' in: \(haystack.prefix(120))"))
        }
        if let tool = action.provenance.mcpTool,
           tool.range(of: Self.mcpToolPattern, options: .regularExpression) != nil {
            findings.append(Finding(detector: id, invariantID: invariantID, confidence: .suspect,
                                    severity: .high, trips: true,
                                    note: "MCP tool '\(tool)' looks like external communication"))
        }
        return findings
    }

    private static func haystack(for action: ProposedAction) -> String {
        var parts: [String] = [action.rawVerb]
        if let payload = action.payloadText { parts.append(payload) }
        if let args = action.arguments {
            for value in args.values where !value.isEmpty { parts.append(value) }
        }
        if let tool = action.provenance.mcpTool { parts.append(tool) }
        return parts.joined(separator: " ")
    }
}
