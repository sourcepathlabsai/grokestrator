import Foundation

// MARK: - The corpus (structured half): invariants + classifications
//
// Per the corpus-architecture conceptualization, the corpus is ONE graph authored
// in TWO media: prose (goals/decisions/rationale → Obsidian) and structure
// (classifications/detectors/taxonomy → the repo). The two halves join at the
// **invariant**, which is Janus-faced: a prose `statement` that grounds a judge, and
// a structured `detectorID` that runs as a check.
//
// This file is the structured half, code-literal for the first slice. The real
// authoring format is a committed repo file (JSON in this same shape) loaded at
// corpus-build time; embedding the seed here lets the slice run end-to-end without
// SwiftPM resource plumbing. Everything is `Codable`, so the on-disk format is the
// literal serialization of these types — the format *is* proven by being loadable.

/// An invariant — the keystone artifact, built first because it is the structural
/// joint between prose and structure (design/13). The tuple:
/// `(statement, detector?, scope, rationale, severity, state, provenance)`. It does
/// double duty: `statement` is the grounding context injected into a judge (lifting
/// semantic accuracy), `detectorID` is the deterministic/recall check.
public struct Invariant: Sendable, Codable, Identifiable {
    public enum State: String, Sendable, Codable { case proposed, active, retired }
    public var id: String                 // INV-… (stable; detectors reference this)
    public var statement: String          // prose face — read by meaning, grounds the judge
    public var rationale: String
    public var detectorID: String?        // structured face — nil ⇒ grounding-only (no precise/recall check yet)
    public var severity: Severity
    public var state: State
    public var provenance: String         // who asserted it (curated corpus, here)
    public init(id: String, statement: String, rationale: String, detectorID: String? = nil,
                severity: Severity, state: State = .active, provenance: String = "seed") {
        self.id = id; self.statement = statement; self.rationale = rationale
        self.detectorID = detectorID; self.severity = severity; self.state = state
        self.provenance = provenance
    }
}

/// The identity an Action is matched on — keyed off *stable* identifiers (verb, MCP
/// server/tool, the agent's `kind` hint). The key index is exact, total, fail-closed:
/// no match ⇒ `classify` returns nil ⇒ the engine escalates (unknown → human).
public struct ActionIdentity: Sendable, Codable, Hashable {
    public var verb: String?
    public var mcpServer: String?
    public var mcpTool: String?
    /// Specificity: more non-nil fields = a tighter match, preferred during lookup.
    var specificity: Int { [verb, mcpServer, mcpTool].compactMap { $0 }.count }
    public init(verb: String? = nil, mcpServer: String? = nil, mcpTool: String? = nil) {
        self.verb = verb; self.mcpServer = mcpServer; self.mcpTool = mcpTool
    }
    func matches(_ a: ProposedAction) -> Bool {
        if let verb, verb != a.verb { return false }
        if let mcpServer, mcpServer != a.provenance.mcpServer { return false }
        if let mcpTool, mcpTool != a.provenance.mcpTool { return false }
        return verb != nil || mcpServer != nil || mcpTool != nil
    }
}

/// A seed-library / classification entry — the first *structured* corpus component.
/// Maps an Action identity to a side-effect class + attributes + a severity floor.
/// Follows the threat-DB pattern: a curated baseline, extended by local accretion
/// (the unknown→human→curate event mints new entries that flow back to the repo).
public struct Classification: Sendable, Codable {
    public var identity: ActionIdentity
    public var sideEffect: SideEffectClass
    public var attributes: SideEffectAttributes
    public var severityFloor: Severity
    public var rationale: String
    public var provenance: String        // trust source (curated seed here)
    public init(identity: ActionIdentity, sideEffect: SideEffectClass,
                attributes: SideEffectAttributes, severityFloor: Severity = .info,
                rationale: String, provenance: String = "seed") {
        self.identity = identity; self.sideEffect = sideEffect; self.attributes = attributes
        self.severityFloor = severityFloor; self.rationale = rationale; self.provenance = provenance
    }
}

/// The materialized runtime corpus: invariants + classifications + detectors, built
/// from the two authoring homes (here: the code-literal seed). Authoritative over
/// nothing — rebuildable from source; fail-closed if it can't be built.
public struct Corpus: Sendable {
    public var invariants: [Invariant]
    public var classifications: [Classification]
    public var detectors: [any Detector]

    public init(invariants: [Invariant], classifications: [Classification], detectors: [any Detector]) {
        self.invariants = invariants; self.classifications = classifications; self.detectors = detectors
    }

    /// Key-index lookup: the most specific classification whose identity matches, or
    /// nil (⇒ unknown ⇒ fail closed). Exact, deterministic — never fuzzy (a fuzzy
    /// key index is the fail-open hole an adversary wants).
    public func classify(_ action: ProposedAction) -> Classification? {
        classifications
            .filter { $0.identity.matches(action) }
            .max { $0.identity.specificity < $1.identity.specificity }
    }

    public func invariant(_ id: String) -> Invariant? { invariants.first { $0.id == id } }
}

// MARK: - The seed corpus (curated baseline)

public extension Corpus {
    /// The bootstrap corpus for the shadow slice. Small and honest: a handful of
    /// classifications for the verbs we actually see, three invariants exercising the
    /// membrane (one precise/definitive, one recall/suspect, one grounding-only), and
    /// the two detectors. MCP tools are deliberately *not* enumerated — an unknown MCP
    /// tool falls through to fail-closed (escalate), which is the behavior we want to
    /// watch in shadow against real servers (Granted, etc.).
    static var seed: Corpus {
        let classifications: [Classification] = [
            Classification(identity: .init(verb: "fs.read"), sideEffect: .observe,
                           attributes: .init(reversible: true, external: false, scope: .node),
                           severityFloor: .info, rationale: "Reading a file changes nothing."),
            Classification(identity: .init(verb: "fs.list"), sideEffect: .observe,
                           attributes: .init(reversible: true, external: false, scope: .node),
                           severityFloor: .info, rationale: "Listing a directory changes nothing."),
            Classification(identity: .init(verb: "fs.write"), sideEffect: .mutate,
                           attributes: .init(reversible: true, external: false, scope: .node),
                           severityFloor: .low, rationale: "Writing a file mutates recoverable node-local state."),
            Classification(identity: .init(verb: "shell"), sideEffect: .execute,
                           attributes: .init(reversible: false, external: true, scope: .host),
                           severityFloor: .high,
                           rationale: "Shell runs arbitrary code on the host — a wildcard; its true class hides in the payload."),
            Classification(identity: .init(verb: "delegate"), sideEffect: .delegate,
                           attributes: .init(reversible: false, external: false, scope: .node),
                           severityFloor: .low, rationale: "Hands a sub-task (and authority) to a child agent."),
        ]
        let invariants: [Invariant] = [
            Invariant(id: "INV-cwd-confinement",
                      statement: "File actions must stay within the node's working directory.",
                      rationale: "A node is sandboxed to its cwd; a path escape is an out-of-bounds reach.",
                      detectorID: PathEscapeDetector.detectorID, severity: .high),
            Invariant(id: "INV-no-destructive-shell",
                      statement: "Shell commands must not irreversibly destroy data without human confirmation.",
                      rationale: "Irreversible bulk deletion (rm -rf, mkfs, dd, force-push) is unrecoverable by the system.",
                      detectorID: DestructiveShellDetector.detectorID, severity: .critical),
            Invariant(id: "INV-external-comms-reviewed",
                      statement: "Actions that communicate externally (email, posting) must be human-reviewed before sending.",
                      rationale: "External communication is irreversible and speaks for the user — the canonical 'put it in front of a human' case.",
                      detectorID: nil, severity: .high),   // grounding-only: no precise/recall detector yet; classification drives it
        ]
        let detectors: [any Detector] = [PathEscapeDetector(), DestructiveShellDetector()]
        return Corpus(invariants: invariants, classifications: classifications, detectors: detectors)
    }
}
