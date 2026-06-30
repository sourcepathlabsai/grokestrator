import Foundation

// MARK: - The pipeline (one coherent machine)
//
// Action → classify (key index) → gather findings (fidelity-gated detectors) →
// severity → escalation outcome. Fail-closed: an unknown classification escalates;
// a definitive irreversible trip blocks. (design/13.)
//
// The engine is an immutable value built from a `Corpus`; a shared shadow instance
// is exposed for the wiring. Pure, Sendable, synchronous — the semantic/judge tier
// (the LLM call a `suspect` finding would ground) is intentionally *not* here yet;
// in shadow v0 a suspect escalates, and the log records what a judge would have seen.
public struct GovernanceEngine: Sendable {
    public let corpus: Corpus
    public init(corpus: Corpus) { self.corpus = corpus }

    /// The shared shadow-mode engine, built from the code baseline (fallback when a project
    /// has no `design/oracle/`).
    public static let shadow = GovernanceEngine(corpus: .seed)

    /// Build an engine from a project's own `design/oracle/` (loaded from its working
    /// directory), merged over the universal baseline. This is the project-owned oracle —
    /// it travels with the repo, not the app. No oracle in the project ⇒ baseline only.
    public static func forProject(directory: String) -> GovernanceEngine {
        GovernanceEngine(corpus: OracleLoader.loadCorpus(projectDirectory: directory))
    }

    public func evaluate(_ action: ProposedAction) -> Verdict {
        // 1. Classify against the key index.
        let classification = corpus.classify(action)

        // 2. Run every detector the Action's fidelity permits; below `minimumFidelity`
        //    a detector abstains (recorded implicitly by its absence, not as a pass).
        var findings: [Finding] = []
        var abstained: [String] = []
        for det in corpus.detectors {
            if action.fidelity >= det.minimumFidelity {
                findings.append(contentsOf: det.examine(action))
            } else {
                abstained.append(det.id)
            }
        }

        // 3. Severity = max(classification floor, all findings).
        let floor = classification?.severityFloor ?? .info
        let severity = max(floor, findings.map(\.severity).max() ?? .info)

        // 4. Fold to an outcome.
        let tripping = findings.filter(\.trips)
        let outcome = decide(classification: classification, tripping: tripping, severity: severity)

        let attrs = classification?.attributes ?? .init()
        let rationale = explain(action: action, classification: classification,
                                tripping: tripping, abstained: abstained, outcome: outcome)
        return Verdict(outcome: outcome, sideEffect: classification?.sideEffect, attributes: attrs,
                       severity: severity, findings: findings, rationale: rationale)
    }

    /// The escalation rule. Directional and conservative: a definitive irreversible
    /// trip blocks; a suspect trip or an escalation-grade side effect escalates; an
    /// unknown classification fails closed (escalate); otherwise allow.
    private func decide(classification: Classification?, tripping: [Finding], severity: Severity) -> Outcome {
        // Definitive trip on an irreversible/high-severity invariant ⇒ block.
        if tripping.contains(where: { $0.confidence == .definitive && $0.severity >= .high }) {
            return .block
        }
        // Any tripping finding (incl. suspect) ⇒ escalate to a human/judge.
        if !tripping.isEmpty { return .escalate }
        // Unknown classification ⇒ fail closed. We don't know the side effect, so we
        // can't clear it (the trust model: raise freely, lower only on authority/proof).
        guard let c = classification else { return .escalate }
        // Escalation-grade side effects always surface, even with no detector trip.
        switch c.sideEffect {
        case .destroy, .transact:           return .escalate
        case .communicate where c.attributes.external == true: return .escalate
        case .execute where severity >= .high: return .escalate
        default:                            return .allow
        }
    }

    private func explain(action: ProposedAction, classification: Classification?,
                         tripping: [Finding], abstained: [String], outcome: Outcome) -> String {
        var parts: [String] = []
        if let c = classification {
            parts.append("classified \(c.sideEffect.rawValue) (\(c.provenance))")
        } else {
            parts.append("UNKNOWN action '\(action.verb)' [\(action.rawVerb)] — fail-closed")
        }
        for f in tripping {
            let inv = f.invariantID.map { " [\($0)]" } ?? ""
            parts.append("\(f.confidence.rawValue) trip\(inv): \(f.note)")
        }
        if !abstained.isEmpty {
            parts.append("abstained(fidelity<\(action.fidelity)): \(abstained.joined(separator: ","))")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Boundary adapters — build a ProposedAction from each interception point
//
// The unification claim, tested: one Action constructible from BOTH boundaries. It
// holds for the *shape* — but the two carry very different fidelity, which the
// adapters make explicit. This is the single biggest "where we're wrong" finding:
// the precise/recall split is partly forced by the boundary, not freely chosen.

public extension ProposedAction {
    /// Build from the **API tool loop** (`OpenAICompatSession.executeTool`): full,
    /// typed arguments ⇒ `.structured`. The richest interception point — the app
    /// executes the tool, so it sees everything before it runs.
    static func fromAPITool(name: String, arguments: [String: String]?, cwd: String?,
                            nodeName: String?, mcpServer: String?, mcpTool: String?) -> ProposedAction {
        ProposedAction(
            verb: VerbNormalizer.fromAPIToolName(name),
            rawVerb: name,
            arguments: arguments,
            payloadText: arguments?["command"] ?? arguments?["path"],
            context: .init(workingDirectory: cwd, nodeName: nodeName),
            provenance: .init(boundary: .apiToolLoop, agentName: "api", mcpServer: mcpServer, mcpTool: mcpTool),
            fidelity: .structured
        )
    }

    /// Build from the **ACP permission** boundary (`session/request_permission`): a
    /// coarse `kind`, a `variant` (e.g. "Bash"), an optional command string, and a
    /// title. No general structured args ⇒ `.semiStructured` (or `.opaque` if even the
    /// command/title is missing). The agent's `kind` is captured as an *untrusted hint*.
    static func fromACPPermission(kind: String?, variant: String?, command: String?,
                                  title: String?, agentName: String?, cwd: String?,
                                  nodeName: String?) -> ProposedAction {
        let payload = command ?? title
        let adapter = VerbNormalizer.inferACPAdapter(agentName: agentName)
        return ProposedAction(
            verb: VerbNormalizer.fromACPPermission(kind: kind, variant: variant, command: command,
                                                   title: title, adapter: adapter),
            rawVerb: variant ?? kind ?? title ?? "permission",
            arguments: command.map { ["command": $0] },
            payloadText: payload,
            context: .init(workingDirectory: cwd, nodeName: nodeName),
            provenance: .init(boundary: .acpPermission, agentName: agentName, grokKind: kind),
            fidelity: payload == nil ? .opaque : .semiStructured
        )
    }
}
