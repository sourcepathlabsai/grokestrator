import Testing
import Foundation
@testable import GrokestratorCore

@Suite("OrchestrationMode")
struct OrchestrationModeTests {

    private let catalog = BrainCatalog(profiles: [
        BrainProfile(name: "Cerebras", backend: .openAICompatible(
            baseURL: "https://api.cerebras.ai/v1", model: "gpt-oss-120b", apiKeyRef: "CEREBRAS_API_KEY"
        )),
    ])

    @Test("grok binding is supervised agent")
    func grokIsSupervised() {
        let mode = OrchestrationSupport.mode(for: .grok, catalog: catalog, tierMap: .default)
        #expect(mode == .supervisedAgent)
        #expect(!OrchestrationSupport.supportsFleetOrchestration(brain: .grok, catalog: catalog, tierMap: .default))
    }

    @Test("API profile binding is orchestrated fleet")
    func apiProfileIsFleet() throws {
        let id = try #require(catalog.profiles.first?.id)
        let mode = OrchestrationSupport.mode(for: .profile(id), catalog: catalog, tierMap: .default)
        #expect(mode == .orchestratedFleet)
    }

    @Test("acpStdio backend is supervised agent")
    func acpStdioIsSupervised() {
        let backend = AgentBackend.acpStdio(command: "/usr/bin/claude-code-acp", arguments: [], label: "Claude")
        #expect(OrchestrationSupport.isACPBackend(backend))
    }

    @Test("ChildFindingEnvelope round-trips JSON")
    func envelopeParse() throws {
        let env = ChildFindingEnvelope(
            status: .success,
            summary: "Found 3 issues",
            findings: [.init(id: "f1", kind: "fact", statement: "Auth uses JWT")]
        )
        let data = try JSONEncoder().encode(env)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(ChildFindingEnvelope.parse(from: text)?.summary == "Found 3 issues")
        #expect(ChildFindingEnvelope.formatDelegateResult(text, childName: "coder").contains("Structured findings"))
    }

    @Test("Prose-only delegate result is wrapped with warning")
    func envelopeProseWrap() {
        let out = ChildFindingEnvelope.formatDelegateResult("plain prose answer", childName: "research-code")
        #expect(out.contains("prose, not a structured finding envelope"))
    }
}