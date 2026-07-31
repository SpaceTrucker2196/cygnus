import Testing
import Foundation
@testable import CygnusExtractorBuild
import CygnusGraph
import CygnusObservation
import CygnusProviders

// Build files as evidence. The extractor states what a build file
// says; it never decides whether the thing named exists.

@Suite struct BuildExtractorTests {
    private func file(_ path: String) -> SnapshotFile {
        SnapshotFile(path: path, blob: BlobHash("deadbeef"), size: 0, languageHint: nil)
    }

    private func observations(_ text: String, path: String) throws -> [Observation] {
        try BuildExtractor().extract(file: file(path), content: Data(text.utf8))
    }

    private func targets(_ observations: [Observation]) -> [String] {
        var seen: [String] = []
        for observation in observations {
            guard case .string(let name)? = observation.payload[ObservationPayload.buildTarget]
            else { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private func dependencies(_ observations: [Observation], of target: String) -> [String] {
        observations.compactMap { observation in
            guard case .string(let name)? = observation.payload[ObservationPayload.buildTarget],
                  name == target,
                  case .string(let dependency)?
                    = observation.payload[ObservationPayload.buildDependency]
            else { return nil }
            return dependency
        }
    }

    // MARK: - Claiming

    @Test func claimsBuildFilesAndNothingElse() {
        let extractor = BuildExtractor()
        #expect(extractor.claims(file: file("Makefile")))
        #expect(extractor.claims(file: file("sub/GNUmakefile")))
        #expect(extractor.claims(file: file("build/rules.mk")))
        #expect(extractor.claims(file: file("fastlane/Fastfile")))
        #expect(!extractor.claims(file: file("Sources/App.swift")))
        #expect(!extractor.claims(file: file("README.md")))
        // A Fastfile outside fastlane/ is not evidence about the build.
        #expect(!extractor.claims(file: file("docs/examples/Fastfile")))
    }

    // MARK: - Make

    @Test func readsTargetsAndPrerequisites() throws {
        let observed = try observations("""
            .PHONY: all test

            all: app test

            app: src/main.c src/util.c
            \tclang -o app src/main.c src/util.c

            test: app
            \t./app --test
            """, path: "Makefile")

        #expect(targets(observed) == ["all", "app", "test"])
        #expect(dependencies(observed, of: "all") == ["app", "test"])
        #expect(dependencies(observed, of: "app") == ["src/main.c", "src/util.c"])
        // Recipe lines are not dependencies.
        #expect(!dependencies(observed, of: "test").contains("./app"))
    }

    /// A target with nothing to depend on is still a fact.
    @Test func aTargetWithNoPrerequisitesIsStillObserved() throws {
        let observed = try observations("clean:\n\trm -rf build\n", path: "Makefile")
        #expect(targets(observed) == ["clean"])
        #expect(dependencies(observed, of: "clean").isEmpty)
    }

    @Test func expandsSimpleVariablesAndJoinsContinuations() throws {
        let observed = try observations("""
            SRCDIR = src
            OBJS = a.o \\
                   b.o

            app: $(OBJS) $(SRCDIR)/main.c
            \tclang -o app
            """, path: "Makefile")
        let deps = dependencies(observed, of: "app")
        #expect(deps.contains("src/main.c"), "variable in a path should expand: \(deps)")
        #expect(deps.contains("a.o") && deps.contains("b.o"),
                "continuation lines should join: \(deps)")
    }

    /// Pattern rules describe a shape, not a thing, so they have no
    /// identity to give an entity. Assignments are not rules.
    @Test func skipsPatternRulesAndAssignments() throws {
        let observed = try observations("""
            CC := clang
            CFLAGS ?= -O2
            LDFLAGS = -lm

            %.o: %.c
            \t$(CC) -c $<

            app: main.o
            """, path: "Makefile")
        #expect(targets(observed) == ["app"])
    }

    /// The same target stated twice is one target, not two.
    @Test func mergesRulesSplitAcrossTheFile() throws {
        let observed = try observations("""
            app: a.c

            app: b.c
            """, path: "Makefile")
        #expect(targets(observed) == ["app"])
        #expect(dependencies(observed, of: "app") == ["a.c", "b.c"])
    }

    // MARK: - fastlane

    @Test func readsLanesAndSubLaneCalls() throws {
        let observed = try observations("""
            default_platform(:ios)

            platform :ios do
              private_lane :setup do
                cocoapods
              end

              lane :beta do
                setup
                build_app(scheme: "App")
                upload_to_testflight
              end

              lane :release do
                beta
              end
            end
            """, path: "fastlane/Fastfile")

        #expect(targets(observed) == ["setup", "beta", "release"])
        #expect(dependencies(observed, of: "beta") == ["setup"])
        #expect(dependencies(observed, of: "release") == ["beta"])
        // A fastlane action is a step, not a coupling between lanes.
        #expect(!dependencies(observed, of: "beta").contains("build_app"))
    }

    @Test func laneCallsBySymbolAreFound() {
        #expect(FastfileLanes.invocations(in: "lane_name(:deploy)").contains("deploy"))
        #expect(FastfileLanes.invocations(in: "# deploy").isEmpty)
    }

    @Test func aLaneDoesNotDependOnItself() throws {
        let observed = try observations("""
            lane :loop do
              loop
            end
            """, path: "fastlane/Fastfile")
        #expect(dependencies(observed, of: "loop").isEmpty)
    }
}
