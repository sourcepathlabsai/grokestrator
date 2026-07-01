import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Harness templates")
struct HarnessTemplateTests {
    @Test func builtinsIncludePlainAndPresets() {
        #expect(GrokHarnessTemplate.builtins.contains(where: { $0.id == "plain" }))
        #expect(GrokHarnessTemplate.presetTemplates.count == 2)
    }

    @Test func registryRoundTrips() throws {
        let custom = GrokHarnessTemplate.blank(id: "my-harness")
        let registry = HarnessTemplateRegistry(custom: [custom])
        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(HarnessTemplateRegistry.self, from: data)
        #expect(decoded == registry)
    }

    @Test func plainWritesNoFiles() {
        let plan = GrokConfigWriter.plan(template: .plain, scope: .userDefaults, projectCWD: nil)
        #expect(plan.operations.isEmpty)
    }
}