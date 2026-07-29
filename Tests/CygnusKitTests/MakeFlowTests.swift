import Testing
import Foundation
@testable import CygnusKit

struct MakeFlowTests {
    private let makefile = """
    CC = clang
    CFLAGS := -O2 -Wall

    .PHONY: all clean

    all: sloth

    sloth: main.o net.o
    \t$(CC) $(CFLAGS) -o sloth main.o net.o

    main.o: main.c
    \t@echo compiling main
    \t$(CC) $(CFLAGS) -c main.c

    net.o: net.c
    \t$(CC) $(CFLAGS) -c net.c

    clean:
    \trm -f sloth *.o
    """

    @Test func parsesTargetsPrereqsAndRecipes() {
        let targets = MakeFlowBuilder.parseTargets(fromMakefile: makefile)
        let names = targets.map(\.name)
        // Assignments (CC, CFLAGS) are not rules; every real target is.
        #expect(names == ["all", "sloth", "main.o", "net.o", "clean"])
        #expect(!names.contains("CC"))

        let sloth = targets.first { $0.name == "sloth" }!
        #expect(sloth.prerequisites == ["main.o", "net.o"])
        // `$(CC)` is kept as its make-variable name — no shell/var
        // expansion, that's honest to what the Makefile literally says.
        #expect(sloth.recipe == ["CC"])

        let mainO = targets.first { $0.name == "main.o" }!
        // `@echo` keeps its command word (prefix stripped); then $(CC).
        #expect(mainO.recipe == ["echo", "CC"])

        let all = targets.first { $0.name == "all" }!
        #expect(all.isPhony)
    }

    @Test func buildsFlowWithDependencyEdges() {
        let flow = MakeFlowBuilder.build(makefileText: makefile)
        #expect(flow.source == .make)
        #expect(!flow.isEmpty)

        // The default goal `all` gets an entry node.
        #expect(flow.nodes.contains { $0.kind == .trigger })
        // Every target is a lane-kind node.
        #expect(flow.nodes.first { $0.id == "target:sloth" }?.kind == .lane)

        // Prerequisite wiring: main.o and net.o feed sloth.
        #expect(flow.edges.contains { $0.from == "target:main.o" && $0.to == "target:sloth" })
        #expect(flow.edges.contains { $0.from == "target:net.o" && $0.to == "target:sloth" })

        // Recipe commands become chained action nodes.
        #expect(flow.nodes.contains { $0.kind == .action && $0.label == "CC" })
        #expect(flow.nodes.contains { $0.kind == .action && $0.label == "echo" })
    }

    @Test func emptyWhenNoTargets() {
        let flow = MakeFlowBuilder.build(makefileText: "CC = clang\nCFLAGS = -O2\n")
        #expect(flow.isEmpty)
        #expect(flow.source == .make)
    }
}
