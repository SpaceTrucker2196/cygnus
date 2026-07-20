import Testing
@testable import CygnusExtractorTS

// E0 spike: prove the SwiftTreeSitter runtime + pinned python/c
// grammars load and parse under Swift 6 strict concurrency.

@Suite struct TreeSitterSpikeTests {
    @Test func pythonGrammarParsesFunctionDefinition() throws {
        let sexp = try TreeSitterHost.parseRootSExpression(
            .python,
            source: """
            import os

            def build_graph(repo):
                return os.path.join(repo, "graph")
            """
        )
        let tree = try #require(sexp)
        #expect(tree.contains("import_statement"))
        #expect(tree.contains("function_definition"))
    }

    @Test func cGrammarParsesIncludeAndFunction() throws {
        let sexp = try TreeSitterHost.parseRootSExpression(
            .c,
            source: """
            #include <stdio.h>

            int main(void) {
                printf("cygnus\\n");
                return 0;
            }
            """
        )
        let tree = try #require(sexp)
        #expect(tree.contains("preproc_include"))
        #expect(tree.contains("function_definition"))
    }

    @Test func brokenSourceStillProducesATree() throws {
        // Error tolerance is why tree-sitter was chosen: visualizing
        // broken code must work.
        let sexp = try TreeSitterHost.parseRootSExpression(
            .python,
            source: "def broken(:\n    pass"
        )
        let tree = try #require(sexp)
        // Recovery shows up as ERROR or MISSING nodes; either proves
        // the parse survived.
        #expect(tree.contains("ERROR") || tree.contains("MISSING"))
        #expect(tree.contains("pass_statement"))
    }
}
