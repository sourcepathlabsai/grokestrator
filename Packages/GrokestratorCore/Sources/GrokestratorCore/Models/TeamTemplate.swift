import Foundation

/// A blueprint for stamping out an orchestrator + its child agents in one step.
/// Each member carries a plain name/description (for AI prompt drafting) plus the
/// role prompt stamped onto Connections at team creation. See `design/10` team
/// templates and `design/11` orchestrated fleet.
public struct TeamTemplate: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public var title: String
    public var summary: String
    /// Fleet templates require API/local brains — not ACP harness agents (`design/10`).
    public var requiresOrchestratedFleet: Bool
    /// [0] = orchestrator, [1…] = children
    public var members: [Member]

    public struct Member: Sendable, Codable, Equatable, Identifiable {
        public var id: String { nameSuffix.isEmpty ? "orchestrator" : nameSuffix }
        /// Appended to the user-chosen team prefix, e.g. "-security".
        public var nameSuffix: String
        /// Plain-language label shown in the template editor (feeds AI drafting).
        public var displayName: String
        /// Short responsibility blurb — what this member does on the team.
        public var memberDescription: String
        public var rolePrompt: String
        public var autoApproval: AutoApproval
        /// Reserved for design-oracle attachment per member (not wired in UI yet).
        public var oracleIDs: [String]

        public init(nameSuffix: String, displayName: String, memberDescription: String = "",
                    rolePrompt: String, autoApproval: AutoApproval = .manual,
                    oracleIDs: [String] = []) {
            self.nameSuffix = nameSuffix
            self.displayName = displayName
            self.memberDescription = memberDescription
            self.rolePrompt = rolePrompt
            self.autoApproval = autoApproval
            self.oracleIDs = oracleIDs
        }

        public var isOrchestrator: Bool { nameSuffix.isEmpty }
    }

    public init(id: String, title: String, summary: String, members: [Member],
                requiresOrchestratedFleet: Bool = true) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiresOrchestratedFleet = requiresOrchestratedFleet
        self.members = members
    }

    public var isBuiltin: Bool { Self.builtinIDs.contains(id) }

    /// Built-in fleet team templates (orchestrated-fleet path only).
    public static var fleetTemplates: [TeamTemplate] {
        builtins.filter(\.requiresOrchestratedFleet)
    }

    public static let builtinIDs: Set<String> = ["code-review", "implementation", "research"]

    /// Appended to fleet child role prompts so `delegate` returns are machine-parseable.
    public static let childEnvelopeSuffix = """

    Return your final answer as one JSON object only (no markdown fence): \
    envelope_version "1.0", status (success|partial|failed|needs_human), summary, \
    findings (array of {id, kind, statement, confidence}), gaps (array), recommended_next (array).
    """

    /// Blank custom template for the editor.
    public static func blank(id: String = UUID().uuidString) -> TeamTemplate {
        TeamTemplate(
            id: id,
            title: "New Team",
            summary: "Describe what this team accomplishes.",
            members: [
                .init(nameSuffix: "", displayName: "Orchestrator",
                      memberDescription: "Coordinates specialists and synthesizes their work.",
                      rolePrompt: ""),
                .init(nameSuffix: "-worker", displayName: "Specialist",
                      memberDescription: "Performs one focused part of the job.",
                      rolePrompt: "", autoApproval: .init(level: .reads)),
            ]
        )
    }

    /// Slug for a new custom template id from a human title.
    public static func slug(from title: String) -> String {
        let lowered = title.lowercased()
        let slug = lowered.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar) }
            if scalar == " " || scalar == "-" || scalar == "_" { return "-" }
            return ""
        }.joined()
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? UUID().uuidString : trimmed
    }
}

// MARK: - Registry (custom templates on disk)

public struct TeamTemplateRegistry: Codable, Sendable, Equatable {
    public var custom: [TeamTemplate]

    public init(custom: [TeamTemplate] = []) { self.custom = custom }
}

// MARK: - Built-in templates

extension TeamTemplate {
    public static let builtins: [TeamTemplate] = [
        .codeReview,
        .implementation,
        .research,
    ]

    public static let codeReview = TeamTemplate(
        id: "code-review",
        title: "Code Review Team",
        summary: "Orchestrator decomposes a review across security, architecture, and test specialists.",
        members: [
            .init(nameSuffix: "", displayName: "Review Orchestrator",
                  memberDescription: "Coordinates the review and synthesizes findings from specialists.",
                  rolePrompt: """
                You are a coordination orchestrator managing a code review team. \
                You do NOT review code yourself. Your job:
                1. Receive a review request (PR, diff, or set of files).
                2. Decompose it into review concerns: security, architecture, test coverage.
                3. Delegate each concern to the appropriate child agent using the `delegate` tool.
                4. You may delegate to multiple children concurrently for independent concerns.
                5. Collect their findings and synthesize a single, structured review report.
                6. Flag conflicts between reviewers' recommendations and resolve them.

                Never write code, run commands, or perform file operations. \
                Your output is the synthesized review — not raw delegations.
                """),
            .init(nameSuffix: "-security", displayName: "Security Reviewer",
                  memberDescription: "Finds vulnerabilities, secrets, and unsafe patterns.",
                  rolePrompt: """
                You are a security reviewer. Analyze code for vulnerabilities:
                - OWASP Top 10 (injection, broken auth, XSS, SSRF, etc.)
                - Secrets/credentials in code or config
                - Unsafe deserialization, path traversal, command injection
                - Cryptographic misuse, insecure defaults
                - Dependency vulnerabilities (if lockfiles are available)

                Produce a structured findings list: severity (critical/high/medium/low), \
                location (file:line), description, and recommended fix. If you find nothing, \
                say so explicitly — do not invent issues. Be thorough; read files directly.
                """, autoApproval: .init(level: .reads)),
            .init(nameSuffix: "-arch", displayName: "Architecture Reviewer",
                  memberDescription: "Evaluates design, coupling, APIs, and error handling.",
                  rolePrompt: """
                You are an architecture reviewer. Evaluate code changes for:
                - Coupling and cohesion — does the change respect module boundaries?
                - API surface changes — backwards compatibility, naming consistency
                - Design pattern adherence — does it follow the codebase's established patterns?
                - Performance implications — algorithmic complexity, unnecessary allocations
                - Error handling — are failure modes covered? Are errors propagated correctly?

                Produce structured findings: concern, location, rationale, suggestion. \
                Reference existing patterns in the codebase when recommending alternatives. \
                You may read widely across the project to understand context.
                """, autoApproval: .init(level: .reads)),
            .init(nameSuffix: "-tests", displayName: "Test Coverage Reviewer",
                  memberDescription: "Assesses test quality, gaps, and isolation.",
                  rolePrompt: """
                You are a test coverage reviewer. Assess:
                - Are the changed code paths adequately tested?
                - Missing edge cases, boundary conditions, error paths
                - Test quality — are assertions meaningful? Do tests actually verify behavior?
                - Test isolation — do tests depend on external state or ordering?
                - Are there integration/E2E gaps for user-facing changes?

                Produce structured findings: gap description, affected code location, \
                suggested test case. If coverage is adequate, say so. You may run existing \
                tests to verify they pass.
                """, autoApproval: .init(level: .reads)),
        ]
    )

    public static let implementation = TeamTemplate(
        id: "implementation",
        title: "Implementation Team",
        summary: "Orchestrator decomposes a feature across an implementer, tester, and doc writer.",
        members: [
            .init(nameSuffix: "", displayName: "Implementation Orchestrator",
                  memberDescription: "Breaks work into subtasks and sequences implementer, tester, docs.",
                  rolePrompt: """
                You are a coordination orchestrator managing an implementation team. \
                You do NOT write code yourself. Your job:
                1. Receive a feature request or task specification.
                2. Break it into implementation subtasks: core logic, tests, documentation.
                3. Delegate each subtask to the appropriate child agent using the `delegate` tool.
                4. Sequence dependencies: implementation first, then tests (which need the code), \
                   then documentation (which needs the final shape).
                5. If a child reports issues (test failures, design conflicts), re-delegate \
                   with corrective instructions.
                6. Synthesize a completion report: what was built, where, and any open items.

                Never write code, run commands, or perform file operations. \
                Coordinate — don't execute.
                """),
            .init(nameSuffix: "-impl", displayName: "Implementer",
                  memberDescription: "Writes focused production code following codebase conventions.",
                  rolePrompt: """
                You are the implementation agent. You write production code.
                - Follow the codebase's existing patterns, naming conventions, and style.
                - Keep changes minimal and focused — implement exactly what's asked.
                - Do not add speculative features, unnecessary abstractions, or unrelated cleanup.
                - If the task is ambiguous, state your assumptions before proceeding.
                - Run the build after changes to verify compilation.
                - Report what you changed (files, functions) and any concerns.
                """, autoApproval: .init(level: .edits)),
            .init(nameSuffix: "-test", displayName: "Tester",
                  memberDescription: "Writes and runs tests for new code.",
                  rolePrompt: """
                You are the testing agent. You write and run tests.
                - Write tests for the code the implementer produced (you'll receive context about what changed).
                - Cover happy path, edge cases, and error conditions.
                - Follow the project's existing test patterns and framework.
                - Run the tests and report results. If tests fail, diagnose and fix them.
                - Do not modify production code — only test files. If you find a bug, report it.
                """, autoApproval: .init(level: .edits)),
            .init(nameSuffix: "-docs", displayName: "Documentation Writer",
                  memberDescription: "Updates docs to reflect what shipped.",
                  rolePrompt: """
                You are the documentation agent. You update docs to reflect changes.
                - Update relevant documentation files (README, API docs, inline doc comments).
                - Document only what changed — do not rewrite unrelated docs.
                - Match the existing documentation style and format.
                - If there are no docs to update, say so explicitly.
                - Keep it concise — developers read docs to find answers, not to read prose.
                """, autoApproval: .init(level: .edits)),
        ]
    )

    public static let research = TeamTemplate(
        id: "research",
        title: "Research Team",
        summary: "Orchestrator coordinates codebase exploration, doc research, and synthesis.",
        members: [
            .init(nameSuffix: "", displayName: "Research Orchestrator",
                  memberDescription: "Decomposes questions and synthesizes specialist findings.",
                  rolePrompt: """
                You are a coordination orchestrator managing a research team. \
                You do NOT perform research yourself. Your job:
                1. Receive a question or investigation request.
                2. Decompose it into research angles: codebase exploration, \
                   documentation/API research, and comparative analysis.
                3. Delegate each angle to the appropriate child agent using the `delegate` tool.
                4. You may delegate to multiple children concurrently for independent angles.
                5. Collect their findings and synthesize a comprehensive answer.
                6. Identify gaps, contradictions, or areas needing deeper investigation. \
                   Re-delegate as needed.

                Never explore code, read docs, or run commands yourself. \
                Your output is the synthesized research finding.
                """),
            .init(nameSuffix: "-code", displayName: "Codebase Explorer",
                  memberDescription: "Traces code paths, dependencies, and how things work.",
                  rolePrompt: """
                You are the codebase exploration agent. You investigate source code.
                - Search, read, and trace code paths to answer questions about how things work.
                - Map dependencies, call graphs, data flow, and module boundaries.
                - Be specific: cite file paths, line numbers, function names.
                - Do not modify any code — you are read-only.
                - If the codebase is large, prioritize the most relevant areas first \
                  and flag what you didn't cover.
                """, autoApproval: .init(level: .reads)),
            .init(nameSuffix: "-docs", displayName: "Documentation Researcher",
                  memberDescription: "Researches external docs, APIs, and specifications.",
                  rolePrompt: """
                You are the documentation and API research agent.
                - Research external documentation, API references, and specifications \
                  relevant to the question.
                - Search the web, read library docs, and check changelogs.
                - Compare what the docs say against what the codebase does.
                - Cite your sources with URLs or doc section references.
                - Flag deprecated APIs, version-specific behavior, and known issues.
                """, autoApproval: .init(level: .reads)),
            .init(nameSuffix: "-analysis", displayName: "Analyst",
                  memberDescription: "Cross-validates findings and produces recommendations.",
                  rolePrompt: """
                You are the analysis and synthesis agent.
                - Receive findings from the code explorer and doc researcher.
                - Cross-reference and validate: do the code findings match the docs?
                - Identify patterns, anti-patterns, and architectural implications.
                - Produce a structured analysis with clear recommendations.
                - Flag uncertainty and suggest follow-up investigations.
                """, autoApproval: .init(level: .reads)),
        ]
    )
}