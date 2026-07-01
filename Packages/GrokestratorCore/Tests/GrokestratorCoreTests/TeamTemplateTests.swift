import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Team templates")
struct TeamTemplateTests {
    @Test func builtinTemplatesHaveDisplayNames() {
        for template in TeamTemplate.builtins {
            #expect(!template.members.isEmpty)
            for member in template.members {
                #expect(!member.displayName.isEmpty)
            }
        }
    }

    @Test func registryRoundTrips() throws {
        let custom = TeamTemplate.blank(id: "my-team")
        let registry = TeamTemplateRegistry(custom: [custom])
        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(TeamTemplateRegistry.self, from: data)
        #expect(decoded == registry)
    }

    @Test func slugFromTitle() {
        #expect(TeamTemplate.slug(from: "My Cool Team") == "my-cool-team")
    }
}