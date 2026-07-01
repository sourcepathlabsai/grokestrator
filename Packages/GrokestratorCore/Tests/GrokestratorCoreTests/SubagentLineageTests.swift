import Testing
@testable import GrokestratorCore

@Test func subagentLineageFormatsTaskDelegation() {
    let line = SubagentLineageReader.formatTaskDelegation(arguments: [
        "subagent_type": "general-purpose",
        "description": "Explore the repo",
    ])
    #expect(line.contains("helper"))
    #expect(line.contains("Explore the repo"))
}

@Test func grokConfigWriterPlansFeatureTeam() {
    let plan = GrokConfigWriter.plan(
        template: .featureTeam,
        scope: .project,
        projectCWD: "/tmp/testproj"
    )
    #expect(!plan.operations.isEmpty)
    #expect(plan.operations.contains { $0.relativePath.hasSuffix("agents/coordinator.md") })
    #expect(plan.operations.contains { $0.relativePath.hasSuffix("roles/implementer.toml") })
}