import Testing
import Foundation
@testable import CygnusGraph

@Suite struct ModelTests {
    @Test func propertyBagRoundTripsThroughJSON() throws {
        let bag: PropertyBag = [
            "core:name": .string("buildGraph"),
            "core:loc": .int(142),
            "core:confidence": .double(0.97),
            "core:public": .bool(true),
            "core:tags": .array([.string("api"), .string("hot")]),
        ]
        let data = try JSONEncoder().encode(bag)
        let decoded = try JSONDecoder().decode(PropertyBag.self, from: data)
        #expect(decoded == bag)
    }

    @Test func kindsAreNamespacedStrings() {
        #expect(EntityKind.function.rawValue == "core:function")
        #expect(RelationshipKind.containsPhysical.rawValue == "core:containsPhysical")
        let pluginKind = EntityKind("k8s:deployment")
        #expect(pluginKind.rawValue.hasPrefix("k8s:"))
    }

    @Test func revisionOrderingIsMonotonic() {
        #expect(RevisionID(1) < RevisionID(2))
        #expect(!(RevisionID(3) < RevisionID(3)))
    }
}
