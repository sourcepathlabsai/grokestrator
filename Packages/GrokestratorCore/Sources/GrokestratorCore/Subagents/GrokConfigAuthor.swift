import Foundation

/// Where harness config files are written (`design/10` rung 2).
public enum GrokConfigScope: String, Sendable, CaseIterable, Identifiable, Codable {
    case project
    case userDefaults

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .project: return "This project (.grok/)"
        case .userDefaults: return "My defaults (~/.grok/)"
        }
    }

    public func baseDirectory(projectCWD: String?) -> URL {
        switch self {
        case .project:
            let raw = projectCWD ?? FileManager.default.currentDirectoryPath
            let cwd = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".grok", isDirectory: true)
        case .userDefaults:
#if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
#else
            return FileManager.default.temporaryDirectory.appendingPathComponent(".grok", isDirectory: true)
#endif
        }
    }
}

public struct GrokAgentDraft: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var model: String
    public var systemPrompt: String

    public init(name: String, description: String = "", model: String = "grok-build", systemPrompt: String = "") {
        self.name = name
        self.description = description
        self.model = model
        self.systemPrompt = systemPrompt
    }

    public func renderedMarkdown() -> String {
        """
        ---
        name: \(name)
        description: \(description)
        model: \(model)
        ---
        \(systemPrompt)
        """
    }
}

public struct GrokRoleDraft: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var capabilityMode: String
    public var model: String
    public var prompt: String

    public init(name: String, description: String, capabilityMode: String = "default",
                model: String = "grok-build", prompt: String = "") {
        self.name = name
        self.description = description
        self.capabilityMode = capabilityMode
        self.model = model
        self.prompt = prompt
    }

    public func renderedTOML() -> String {
        var lines = [
            "description = \"\(description.replacingOccurrences(of: "\"", with: "\\\""))\"",
            "default_capability_mode = \"\(capabilityMode)\"",
            "model = \"\(model)\"",
        ]
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escaped = prompt.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("prompt = \"\(escaped)\"")
        }
        return lines.joined(separator: "\n")
    }
}

public struct GrokPersonaDraft: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Plain-language blurb for AI prompt drafting.
    public var description: String
    public var instructions: String

    public init(name: String, description: String = "", instructions: String = "") {
        self.name = name
        self.description = description
        self.instructions = instructions
    }

    public func renderedTOML() -> String {
        let escaped = instructions.replacingOccurrences(of: "\"", with: "\\\"")
        return "instructions = \"\(escaped)\""
    }
}

/// A harness team template — agent + roles + personas written to `.grok/` for
/// grok's `task` tool (ACP supervision path, `design/10` rung 2).
public struct GrokHarnessTemplate: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public var title: String
    public var summary: String
    public var agent: GrokAgentDraft
    public var roles: [GrokRoleDraft]
    public var personas: [GrokPersonaDraft]

    public init(id: String, title: String, summary: String,
                agent: GrokAgentDraft, roles: [GrokRoleDraft], personas: [GrokPersonaDraft]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.agent = agent
        self.roles = roles
        self.personas = personas
    }

    public var isBuiltin: Bool { Self.builtinIDs.contains(id) }
    /// Plain = no files written.
    public var writesFiles: Bool { id != "plain" }

    public static let builtinIDs: Set<String> = ["plain", "feature-team", "research-team"]

    public static func blank(id: String = UUID().uuidString) -> GrokHarnessTemplate {
        GrokHarnessTemplate(
            id: id,
            title: "New Harness Team",
            summary: "Coordinator + harness subagent roles for grok's task tool.",
            agent: GrokAgentDraft(
                name: "coordinator",
                description: "Coordinates work via harness subagents",
                systemPrompt: ""
            ),
            roles: [
                .init(name: "worker", description: "Performs one focused part of the job.",
                      capabilityMode: "read-only", prompt: ""),
            ],
            personas: []
        )
    }

    public static func slug(from title: String) -> String {
        TeamTemplate.slug(from: title)
    }
}

public struct HarnessTemplateRegistry: Codable, Sendable, Equatable {
    public var custom: [GrokHarnessTemplate]
    public init(custom: [GrokHarnessTemplate] = []) { self.custom = custom }
}

// MARK: - Built-in harness templates

extension GrokHarnessTemplate {
    public static let plain = GrokHarnessTemplate(
        id: "plain",
        title: "Plain",
        summary: "No harness team files — today's default behavior.",
        agent: GrokAgentDraft(name: "agent", description: "Default agent"),
        roles: [],
        personas: []
    )

    public static let featureTeam = GrokHarnessTemplate(
        id: "feature-team",
        title: "Feature Team",
        summary: "Coordinator + implementer + reviewer harness roles for shipping features.",
        agent: GrokAgentDraft(
            name: "coordinator",
            description: "Coordinates feature work via harness subagents",
            systemPrompt: """
            You coordinate feature delivery using the task tool. Decompose work into \
            design, implementation, and review. Delegate to subagents; synthesize their \
            results into a single deliverable. Do not implement substantial work yourself.
            """
        ),
        roles: [
            GrokRoleDraft(name: "implementer", description: "Writes production code",
                          capabilityMode: "execute", prompt: "Implement exactly what is asked. Match codebase style."),
            GrokRoleDraft(name: "reviewer", description: "Reviews changes for quality and risks",
                          capabilityMode: "read-only", prompt: "Review thoroughly. Cite file:line. Be constructive."),
            GrokRoleDraft(name: "architect", description: "Produces design plans",
                          capabilityMode: "read-only", model: "grok-build",
                          prompt: "Produce concise design plans. No code changes."),
        ],
        personas: [
            GrokPersonaDraft(name: "implementer", description: "Ships focused production diffs",
                             instructions: "Ship focused diffs. Run the build after edits."),
            GrokPersonaDraft(name: "reviewer", description: "Structured code review findings",
                             instructions: "Structured findings: severity, location, fix."),
        ]
    )

    public static let researchTeam = GrokHarnessTemplate(
        id: "research-team",
        title: "Research Team",
        summary: "Coordinator + explorer + synthesizer for investigation workflows.",
        agent: GrokAgentDraft(
            name: "coordinator",
            description: "Coordinates research via harness subagents",
            systemPrompt: """
            You coordinate research using the task tool. Decompose questions into \
            exploration angles. Delegate in parallel when independent. Synthesize findings \
            with gaps and recommendations.
            """
        ),
        roles: [
            GrokRoleDraft(name: "explorer", description: "Read-only codebase exploration",
                          capabilityMode: "read-only", prompt: "Search and read. Cite paths and symbols."),
            GrokRoleDraft(name: "synthesizer", description: "Cross-references and summarizes",
                          capabilityMode: "read-only", prompt: "Synthesize findings. Flag uncertainty."),
        ],
        personas: [
            GrokPersonaDraft(name: "researcher", description: "Thorough investigation with citations",
                             instructions: "Be thorough. Cite sources. No speculation without labeling it."),
        ]
    )

    public static let builtins: [GrokHarnessTemplate] = [.plain, .featureTeam, .researchTeam]

    /// Shipped built-ins (excludes Plain sentinel).
    public static var presetTemplates: [GrokHarnessTemplate] {
        builtins.filter { $0.id != "plain" }
    }
}

public struct GrokConfigWritePlan: Sendable {
    public struct FileOp: Sendable, Identifiable {
        public let id: String
        public let relativePath: String
        public let fullURL: URL
        public let newContent: String
        public let existedBefore: Bool
        public var previousContent: String?

        public init(relativePath: String, fullURL: URL, newContent: String,
                    existedBefore: Bool, previousContent: String? = nil) {
            self.id = relativePath
            self.relativePath = relativePath
            self.fullURL = fullURL
            self.newContent = newContent
            self.existedBefore = existedBefore
            self.previousContent = previousContent
        }
    }

    public let scope: GrokConfigScope
    public let operations: [FileOp]

    public var creates: [FileOp] { operations.filter { !$0.existedBefore } }
    public var overwrites: [FileOp] { operations.filter { $0.existedBefore } }
}

/// Builds write plans and applies them to real `.grok/` files.
public enum GrokConfigWriter {
    public static func plan(
        template: GrokHarnessTemplate,
        scope: GrokConfigScope,
        projectCWD: String?,
        agentNameOverride: String? = nil
    ) -> GrokConfigWritePlan {
        guard template.writesFiles else {
            return GrokConfigWritePlan(scope: scope, operations: [])
        }

        let base = scope.baseDirectory(projectCWD: projectCWD)
        var ops: [GrokConfigWritePlan.FileOp] = []

        var agent = template.agent
        if let override = agentNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            agent.name = override
        }
        ops.append(fileOp(base: base, subpath: "agents/\(agent.name).md", content: agent.renderedMarkdown()))

        for role in template.roles {
            ops.append(fileOp(base: base, subpath: "roles/\(role.name).toml", content: role.renderedTOML()))
        }
        for persona in template.personas {
            ops.append(fileOp(base: base, subpath: "personas/\(persona.name).toml", content: persona.renderedTOML()))
        }
        return GrokConfigWritePlan(scope: scope, operations: ops)
    }

    public static func planCustom(
        agent: GrokAgentDraft,
        roles: [GrokRoleDraft],
        personas: [GrokPersonaDraft],
        scope: GrokConfigScope,
        projectCWD: String?
    ) -> GrokConfigWritePlan {
        let base = scope.baseDirectory(projectCWD: projectCWD)
        var ops: [GrokConfigWritePlan.FileOp] = []
        if !agent.name.trimmingCharacters(in: .whitespaces).isEmpty {
            ops.append(fileOp(base: base, subpath: "agents/\(agent.name).md", content: agent.renderedMarkdown()))
        }
        for role in roles where !role.name.isEmpty {
            ops.append(fileOp(base: base, subpath: "roles/\(role.name).toml", content: role.renderedTOML()))
        }
        for persona in personas where !persona.name.isEmpty {
            ops.append(fileOp(base: base, subpath: "personas/\(persona.name).toml", content: persona.renderedTOML()))
        }
        return GrokConfigWritePlan(scope: scope, operations: ops)
    }

    /// Apply a write plan. Skips overwrites unless `overwriteExisting` is true.
    @discardableResult
    public static func apply(_ plan: GrokConfigWritePlan, overwriteExisting: Bool) throws -> Int {
        var written = 0
        for op in plan.operations {
            if op.existedBefore && !overwriteExisting { continue }
            let dir = op.fullURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try op.newContent.write(to: op.fullURL, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }

    public static func loadAgent(name: String, scope: GrokConfigScope, projectCWD: String?) -> GrokAgentDraft? {
        let url = scope.baseDirectory(projectCWD: projectCWD)
            .appendingPathComponent("agents/\(name).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseAgentMarkdown(text, fallbackName: name)
    }

    private static func fileOp(base: URL, subpath: String, content: String) -> GrokConfigWritePlan.FileOp {
        let url = base.appendingPathComponent(subpath)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let previous = existed ? try? String(contentsOf: url, encoding: .utf8) : nil
        return GrokConfigWritePlan.FileOp(
            relativePath: subpath, fullURL: url, newContent: content,
            existedBefore: existed, previousContent: previous
        )
    }

    private static func parseAgentMarkdown(_ text: String, fallbackName: String) -> GrokAgentDraft {
        var name = fallbackName
        var description = ""
        var model = "grok-build"
        var body = text

        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "---")
            if parts.count >= 3 {
                let front = parts[1]
                body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
                for line in front.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") { name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    if trimmed.hasPrefix("description:") { description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces) }
                    if trimmed.hasPrefix("model:") { model = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        return GrokAgentDraft(name: name, description: description, model: model, systemPrompt: body)
    }
}