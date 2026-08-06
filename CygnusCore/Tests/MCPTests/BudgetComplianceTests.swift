import Testing
import Foundation
import CygnusRetrieval
@testable import CygnusMCP

// The contract, asserted across every tool at once.
//
// Individual handlers are easy to get right and easy to regress the
// day someone adds tool number ten and forgets the budget. This sweeps
// the whole catalog at several budgets, so a new tool that ignores its
// ceiling — or truncates without saying so — fails here rather than in
// somebody's context window.

@Suite struct BudgetComplianceTests {
    /// Plausible arguments for every tool, so the sweep exercises real
    /// answers rather than validation errors.
    private static let arguments: [String: [String: JSONValue]] = [
        "cygnus_status": [:],
        "cygnus_prior_decisions": ["topic": .string("storage")],
        "cygnus_repo_map": [:],
        "cygnus_search": ["query": .string("Engine")],
        "cygnus_find_definition": ["symbol": .string("Engine")],
        "cygnus_find_references": ["symbol": .string("Engine")],
        "cygnus_callers_of": ["symbol": .string("Engine")],
        "cygnus_blast_radius": ["symbol": .string("Engine")],
        "cygnus_list_symbols": ["path": .string("Sources/Engine.swift")],
        "cygnus_read_span": [
            "path": .string("Sources/Engine.swift"),
            "start_line": .number(1), "end_line": .number(4),
        ],
    ]

    @Test func everyToolStaysWithinEveryBudget() async throws {
        let handlers = try await Fixtures.handlers()
        for tool in ToolCatalog.tools {
            var arguments = try #require(Self.arguments[tool.name],
                                         "no fixture arguments for \(tool.name)")
            for requested in [200, 500, 2000, tool.maxTokens] {
                arguments["max_tokens"] = .number(Double(requested))
                let text = try await handlers.call(tool.name, arguments: arguments)
                let allowed = min(requested, tool.maxTokens)
                // The emitter reserves footer room and admits headers
                // unconditionally; allow that slack, nothing more.
                #expect(text.utf8.count <= (allowed + TokenBudget.footerReserve) * 3 + 512,
                        "\(tool.name) overran a \(requested)-token budget")
            }
        }
    }

    /// A client must not be able to talk a tool into a bigger response
    /// than its ceiling. A budget that can be raised is not a budget.
    @Test func aClientCannotRaiseAToolsCeiling() {
        for tool in ToolCatalog.tools {
            #expect(ToolCatalog.budget(for: tool, requested: 999_999) == tool.maxTokens)
            #expect(ToolCatalog.budget(for: tool, requested: nil) == tool.maxTokens)
        }
    }

    /// Every tool must be callable and produce something. A tool that
    /// returns an empty string teaches an agent nothing at all.
    @Test func everyToolProducesNonEmptyOutput() async throws {
        let handlers = try await Fixtures.handlers()
        for tool in ToolCatalog.tools {
            let arguments = try #require(Self.arguments[tool.name])
            let text = try await handlers.call(tool.name, arguments: arguments)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(tool.name) returned nothing")
        }
    }

    /// Every tool description has to earn the call against grep and
    /// read, so an empty or perfunctory one is a defect.
    @Test func everyToolDescribesWhenToPreferIt() {
        for tool in ToolCatalog.tools {
            #expect(tool.description.count > 80,
                    "\(tool.name)'s description is too thin to route on")
        }
    }

    @Test func toolNamesAreUniqueAndPrefixed() {
        let names = ToolCatalog.tools.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("cygnus_") })
    }
}
