import Testing
@testable import GrokestratorCore

@Suite("Verb normalizer — harness vocabulary")
struct VerbNormalizerTests {

    // MARK: API tool loop

    @Test("API tool names map to canonical verbs")
    func apiToolMap() {
        #expect(VerbNormalizer.fromAPIToolName("read_file") == "fs.read")
        #expect(VerbNormalizer.fromAPIToolName("list_dir") == "fs.list")
        #expect(VerbNormalizer.fromAPIToolName("write_file") == "fs.write")
        #expect(VerbNormalizer.fromAPIToolName("run_command") == "shell")
        #expect(VerbNormalizer.fromAPIToolName("delegate") == "delegate")
        #expect(VerbNormalizer.fromAPIToolName("mcp__srv__tool") == "mcp.call")
        #expect(VerbNormalizer.fromAPIToolName("custom_tool") == "custom_tool")
    }

    // MARK: ACP adapter inference

    @Test("inferACPAdapter from agent display name")
    func adapterInference() {
        #expect(VerbNormalizer.inferACPAdapter(agentName: "Claude Code") == .claudeCodeACP)
        #expect(VerbNormalizer.inferACPAdapter(agentName: "grok") == .grok)
        #expect(VerbNormalizer.inferACPAdapter(agentName: "Grok Build") == .grok)
        #expect(VerbNormalizer.inferACPAdapter(agentName: "Custom Agent") == .generic)
        #expect(VerbNormalizer.inferACPAdapter(agentName: nil) == .generic)
    }

    // MARK: grok / standard ACP

    @Test("grok adapter: ACP ToolKind mapping")
    func grokKindMapping() {
        #expect(VerbNormalizer.fromACPPermission(kind: "read", variant: nil, command: nil,
                                                 title: nil, adapter: .grok) == "fs.read")
        #expect(VerbNormalizer.fromACPPermission(kind: "execute", variant: "Bash",
                                                 command: "ls", title: "Bash: ls",
                                                 adapter: .grok) == "shell")
        #expect(VerbNormalizer.fromACPPermission(kind: "search", variant: nil, command: nil,
                                                 title: "grep foo", adapter: .grok) == "fs.list")
    }

    // MARK: Claude Code adapter

    @Test("Claude adapter: nil kind + title/command")
    func claudeAdapter() {
        #expect(VerbNormalizer.fromACPPermission(kind: nil, variant: nil, command: "ls -la",
                                                 title: "`ls -la`", adapter: .claudeCodeACP) == "shell")
        #expect(VerbNormalizer.fromACPPermission(kind: nil, variant: nil, command: nil,
                                                 title: "Read src/main.swift",
                                                 adapter: .claudeCodeACP) == "fs.read")
        #expect(VerbNormalizer.fromACPPermission(kind: nil, variant: nil, command: nil,
                                                 title: "Edit `foo.swift`",
                                                 adapter: .claudeCodeACP) == "fs.write")
    }

    // MARK: generic adapter

    @Test("generic adapter: kind first, then title")
    func genericAdapter() {
        #expect(VerbNormalizer.fromACPPermission(kind: "edit", variant: nil, command: nil,
                                                 title: "unrelated", adapter: .generic) == "fs.write")
        #expect(VerbNormalizer.fromACPPermission(kind: nil, variant: nil, command: nil,
                                                 title: "grep \"x\" src/",
                                                 adapter: .generic) == "fs.list")
        #expect(VerbNormalizer.fromACPPermission(kind: nil, variant: nil, command: nil,
                                                 title: "mystery tool", adapter: .generic) == "unknown")
    }

    // MARK: End-to-end via ProposedAction builders

    @Test("fromAPITool uses VerbNormalizer")
    func proposedActionAPITool() {
        let a = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": "ls"],
                                           cwd: "/w", nodeName: nil, mcpServer: nil, mcpTool: nil)
        #expect(a.verb == "shell")
    }

    @Test("fromACPPermission infers Claude adapter from agent name")
    func proposedActionACPWithAgent() {
        let a = ProposedAction.fromACPPermission(
            kind: nil, variant: nil, command: nil,
            title: "Read Package.swift",
            agentName: "Claude Code", cwd: "/w", nodeName: nil)
        #expect(a.verb == "fs.read")
    }
}