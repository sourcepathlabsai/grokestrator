import Foundation

// MARK: - The Design Oracle, runtime governance form (design/13)
//
// This is the first *code* projection of the design-oracle conceptualization
// (canonical write-up: Obsidian "Design Oracle (Operational Form)"). It governs a
// **proposed Action** — NOT a git diff — at the mediated tool boundary the app
// already owns: `OpenAICompatSession.executeTool` (API brains) and
// `GrokBuildSessionClient` `session/request_permission` (ACP brains, grok / Claude).
//
// It ships in **shadow mode**: the engine observes Actions and renders the verdict
// it *would* reach, without changing the allow/deny decision. That is how we find
// out where the conceptual model is wrong against real traffic. `AutoApproval` is
// v0; this oracle is v1; mediation is the precondition for both.
//
// Design notes worth keeping in view (each surfaced building this):
//  • The two boundaries deliver Actions of very different *fidelity* (see
//    `ProposedAction.Fidelity`). The API boundary hands us fully-structured args;
//    the ACP boundary hands us a coarse `kind` + a title/command string. The
//    precise/recall detector split is therefore partly *forced by the boundary*,
//    not freely chosen — so detectors declare a `minimumFidelity` and abstain below
//    it (abstain, never fail-open; the fail-closed-on-unknown rule covers the gap).

/// A proposed Action — the unit of governance. Domain-general by construction: a
/// verb, its arguments/payload, the context it runs in, and where it came from.
/// "Run this shell command", "write this file", "call this MCP tool", "send this
/// email" all reduce to this shape. The oracle never sees a diff.
public struct ProposedAction: Sendable {
    /// How much structure the boundary gave us about this Action. This is the single
    /// most consequential thing we learned wiring it: fidelity is a property of the
    /// *interception point*, and it gates which detectors can even run.
    public enum Fidelity: Int, Sendable, Comparable {
        case opaque = 0          // a human title string only ("Grok is requesting permission")
        case semiStructured = 1  // coarse kind + a command/title string (typical ACP permission)
        case structured = 2      // full, typed arguments (the API tool loop)
        public static func < (l: Fidelity, r: Fidelity) -> Bool { l.rawValue < r.rawValue }
    }

    /// Where the Action was intercepted, and the untrusted hints that boundary
    /// supplied. Per the trust model, the *agent's own* classification of its action
    /// (grok's ACP `kind`) is the lowest-trust source — usable to raise suspicion,
    /// never to clear.
    public struct Provenance: Sendable {
        public enum Boundary: String, Sendable { case apiToolLoop, acpPermission }
        public var boundary: Boundary
        public var agentName: String?     // "grok", "claude-code", … (stable identity for the seed library)
        public var grokKind: String?      // the ACP tool-call `kind` the agent self-assigned (untrusted hint)
        public var mcpServer: String?     // resolved MCP server name when the verb is an MCP tool
        public var mcpTool: String?       // the real (un-namespaced) MCP tool name
        public init(boundary: Boundary, agentName: String? = nil, grokKind: String? = nil,
                    mcpServer: String? = nil, mcpTool: String? = nil) {
            self.boundary = boundary; self.agentName = agentName; self.grokKind = grokKind
            self.mcpServer = mcpServer; self.mcpTool = mcpTool
        }
    }

    /// Context the Action acts within — the part that decides whether a side effect
    /// is in-bounds (e.g. a write inside cwd vs. outside it).
    public struct Context: Sendable {
        public var workingDirectory: String?
        public var nodeName: String?
        public init(workingDirectory: String? = nil, nodeName: String? = nil) {
            self.workingDirectory = workingDirectory; self.nodeName = nodeName
        }
    }

    /// Normalized verb (`fs.read`, `fs.write`, `shell`, `delegate`, `mcp.call`).
    /// The boundary's raw tool name is normalized at construction so classifications
    /// and detectors key off one stable vocabulary.
    public var verb: String
    /// The raw tool name as the boundary named it (`read_file`, `mcp__Granted__search_grants`, …).
    public var rawVerb: String
    /// Structured arguments when the boundary provides them (API loop). Stringized
    /// values keep it Sendable + boundary-agnostic; precise detectors parse as needed.
    public var arguments: [String: String]?
    /// The best human-readable rendering of what the Action will do — a shell command,
    /// a permission title. On `.opaque`/`.semiStructured` Actions this is often the
    /// *only* payload signal, which is why recall (regex) detectors live here.
    public var payloadText: String?
    public var context: Context
    public var provenance: Provenance
    public var fidelity: Fidelity

    public init(verb: String, rawVerb: String, arguments: [String: String]? = nil,
                payloadText: String? = nil, context: Context = .init(),
                provenance: Provenance, fidelity: Fidelity) {
        self.verb = verb; self.rawVerb = rawVerb; self.arguments = arguments
        self.payloadText = payloadText; self.context = context
        self.provenance = provenance; self.fidelity = fidelity
    }
}

// MARK: - Side-effect taxonomy (the domain-general vocabulary)

/// What an Action *does to the world*, on the master axis of reversibility-by-the-
/// system. Domain-general: governs email and shell alike. (design/13 taxonomy.)
public enum SideEffectClass: String, Sendable, Codable, CaseIterable {
    case observe      // read-only; no state change
    case mutate       // changes recoverable state (write a file)
    case destroy      // irreversible loss (rm -rf, drop table)
    case communicate  // emits to a party outside the system (send email, post)
    case transact     // moves money / makes commitments
    case execute      // runs arbitrary code — a wildcard whose true class hides in its payload
    case delegate     // hands authority to another agent
}

/// Orthogonal attributes that sharpen a class. Optional: a classification asserts
/// only what it knows; unknown ⇒ the engine treats it conservatively.
public struct SideEffectAttributes: Sendable, Codable, Hashable {
    public enum Scope: String, Sendable, Codable { case node, host, world }
    public var reversible: Bool?
    public var external: Bool?      // effect escapes the local system
    public var costBearing: Bool?   // spends money / quota
    public var scope: Scope?
    public init(reversible: Bool? = nil, external: Bool? = nil,
                costBearing: Bool? = nil, scope: Scope? = nil) {
        self.reversible = reversible; self.external = external
        self.costBearing = costBearing; self.scope = scope
    }
}

// MARK: - Severity / Findings / Verdict

/// Ordered severity. The engine takes the max over the classification floor and all
/// findings, then maps to an escalation outcome.
public enum Severity: Int, Sendable, Codable, Comparable {
    case info = 0, low = 1, medium = 2, high = 3, critical = 4
    public static func < (l: Severity, r: Severity) -> Bool { l.rawValue < r.rawValue }
}

/// A detector's confidence in its own finding. The precise/recall split, made
/// explicit: `definitive` detectors *decide* (a deterministic check, ~10–20%);
/// `suspect` detectors *flag* (high-recall, regex/heuristic, ~80%) and hand off to
/// a (future) grounded judge — in shadow v0 they simply escalate.
public enum Confidence: String, Sendable, Codable { case definitive, suspect }

/// One detector's observation about an Action, optionally tied to the invariant it
/// is enforcing (the membrane: a finding's `invariantID` is how the structured side
/// reaches back into the prose side to ground a judge).
public struct Finding: Sendable {
    public var detector: String
    public var invariantID: String?
    public var confidence: Confidence
    public var severity: Severity
    /// `true` ⇒ this finding argues the Action should be stopped; `false` ⇒ informational.
    public var trips: Bool
    public var note: String
    public init(detector: String, invariantID: String? = nil, confidence: Confidence,
                severity: Severity, trips: Bool, note: String) {
        self.detector = detector; self.invariantID = invariantID; self.confidence = confidence
        self.severity = severity; self.trips = trips; self.note = note
    }
}

/// What the oracle decides. In shadow mode this is logged, not enforced.
public enum Outcome: String, Sendable, Codable {
    case allow      // within intent; proceed unattended
    case escalate   // surface to a human (or, later, a grounded judge)
    case block      // a definitive, irreversible violation — stop
}

/// The oracle's verdict on one Action: the outcome plus the reasoning that produced
/// it (classification + findings), so the shadow log is legible.
public struct Verdict: Sendable {
    public var outcome: Outcome
    public var sideEffect: SideEffectClass?     // nil ⇒ unknown (fail-closed territory)
    public var attributes: SideEffectAttributes
    public var severity: Severity
    public var findings: [Finding]
    public var rationale: String
    public init(outcome: Outcome, sideEffect: SideEffectClass?, attributes: SideEffectAttributes,
                severity: Severity, findings: [Finding], rationale: String) {
        self.outcome = outcome; self.sideEffect = sideEffect; self.attributes = attributes
        self.severity = severity; self.findings = findings; self.rationale = rationale
    }

    /// A one-line summary for the shadow activity log.
    public var summary: String {
        let se = sideEffect?.rawValue ?? "unknown"
        return "\(outcome.rawValue.uppercased()) · \(se) · sev=\(severity) — \(rationale)"
    }
}
