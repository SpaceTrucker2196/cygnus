import Testing
import Foundation
import CygnusGraph
import CygnusProviders
import CygnusObservation
@testable import CygnusExtractorSwift

@Suite struct SwiftExtractorTests {
    let extractor = SwiftExtractor()

    func extract(_ source: String) throws -> [Observation] {
        let data = Data(source.utf8)
        let file = SnapshotFile(path: "Test.swift", blob: ContentStore.hash(data),
                                size: Int64(data.count), languageHint: "swift")
        return try extractor.extract(file: file, content: data)
    }

    func declPaths(_ observations: [Observation]) -> [String] {
        observations.compactMap {
            guard $0.kind == .declaration,
                  case .string(let path)? = $0.payload[ObservationPayload.declPath]
            else { return nil }
            return path
        }
    }

    @Test func extractsImportsAndNestedDeclarations() throws {
        let observations = try extract("""
            import Foundation
            import CygnusGraph

            struct HTTPClient {
                let session: String
                func send(_ request: String, to host: String) -> Bool { true }
                enum Failure { case timeout }
            }

            protocol Transport {}
            """)

        let imports = observations.filter { $0.kind == .importStatement }
            .compactMap { obs -> String? in
                guard case .string(let m)? = obs.payload[ObservationPayload.module] else { return nil }
                return m
            }
        #expect(imports == ["Foundation", "CygnusGraph"])

        let paths = declPaths(observations)
        #expect(paths.contains("HTTPClient"))
        #expect(paths.contains("HTTPClient.session"))
        #expect(paths.contains("HTTPClient.send(_:to:)"))
        #expect(paths.contains("HTTPClient.Failure"))
        #expect(paths.contains("Transport"))
    }

    @Test func extensionMembersNestUnderExtendedType() throws {
        let paths = declPaths(try extract("""
            extension HTTPClient {
                func retry() {}
            }
            """))
        #expect(paths == ["HTTPClient.retry()"])
    }

    @Test func functionLocalVariablesAreSkipped() throws {
        let paths = declPaths(try extract("""
            func compute() {
                let local = 1
                _ = local
            }
            """))
        #expect(paths == ["compute()"])
    }

    @Test func declarationAnchorsCarryLineRanges() throws {
        let observations = try extract("""
            struct A {}
            """)
        let decl = try #require(observations.first(where: { $0.kind == .declaration }))
        #expect(decl.file.range?.startLine == 1)
        #expect(decl.file.path == "Test.swift")
    }
}
