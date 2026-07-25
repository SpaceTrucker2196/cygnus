import Testing
import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders
@testable import CygnusExtractorTS

@Suite struct RustExtractorTests {
    private func file(_ path: String = "src/lib.rs") -> SnapshotFile {
        SnapshotFile(path: path, blob: BlobHash("abc"), size: 100, languageHint: "rust")
    }

    @Test func extractsRustDeclarationsAndUseImports() throws {
        let source = """
        use std::collections::HashMap;
        use crate::agent::Step;

        pub struct AgentResult { pub steps: Vec<Step> }

        pub enum Action { Run, Stop }

        pub trait Planner { fn plan(&self) -> Action; }

        pub fn run_agent(input: &str) -> AgentResult {
            AgentResult { steps: vec![] }
        }

        mod util {
            pub fn helper() {}
        }
        """
        let obs = try RustExtractor().extract(file: file(), content: Data(source.utf8))
        let names = Set(obs.compactMap { o -> String? in
            guard o.kind == .declaration,
                  case .string(let n)? = o.payload[ObservationPayload.name] else { return nil }
            return n
        })
        #expect(names.isSuperset(of: ["AgentResult", "Action", "Planner", "run_agent", "util"]))

        let modules = Set(obs.compactMap { o -> String? in
            guard o.kind == .importStatement,
                  case .string(let m)? = o.payload[ObservationPayload.module] else { return nil }
            return m
        })
        #expect(modules.contains("std::collections::HashMap"))
        #expect(modules.contains("crate::agent::Step"))

        // Nested fn carries its module in the decl path, not doubled.
        let helper = obs.first { o in
            if case .string("helper")? = o.payload[ObservationPayload.name] { return true }
            return false
        }
        if case .string(let path)? = helper?.payload[ObservationPayload.declPath] {
            #expect(path == "util.helper")
        }
    }

    @Test func claimsRustFiles() {
        #expect(RustExtractor().claims(file: file("a.rs")))
        #expect(!RustExtractor().claims(
            file: SnapshotFile(path: "a.py", blob: BlobHash("x"), size: 1, languageHint: "python")))
    }
}
