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

    /// Pattern rules describe a shape, not an artifact — kept as
    /// facts, flagged as patterns, so the CI Flow chart can draw the
    /// row without the graph pretending `%.o` gets built. Assignments
    /// are still not rules.
    @Test func keepsPatternRulesFlaggedAndSkipsAssignments() throws {
        let observed = try observations("""
            CC := clang
            CFLAGS ?= -O2
            LDFLAGS = -lm

            %.o: %.c
            \t$(CC) -c $<

            app: main.o
            """, path: "Makefile")
        #expect(targets(observed) == ["%.o", "app"])
        let pattern = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("%.o")
        })
        #expect(pattern.payload[ObservationPayload.buildPattern] == .bool(true))
        let app = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("app")
        })
        #expect(app.payload[ObservationPayload.buildPattern] == nil)
    }

    /// `$(TARGET)` expands to the entity's identity, but the spelling
    /// the file uses is a fact too — the chart reads as written.
    @Test func recordsTheVerbatimSpellingWhenExpansionChangedIt() throws {
        let observed = try observations("""
            TARGET = app

            $(TARGET): main.c
            \tclang -o $(TARGET) main.c

            clean:
            \trm -f $(TARGET)
            """, path: "Makefile")
        #expect(targets(observed) == ["app", "clean"])
        let app = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("app")
        })
        #expect(app.payload[ObservationPayload.buildTargetVerbatim] == .string("$(TARGET)"))
        let clean = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("clean")
        })
        #expect(clean.payload[ObservationPayload.buildTargetVerbatim] == nil)
    }

    /// `.PHONY` is a declaration about the target, recorded with it.
    @Test func recordsPhoniness() throws {
        let observed = try observations("""
            .PHONY: all
            all: app
            app: main.c
            \tclang -o app main.c
            """, path: "Makefile")
        let all = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("all")
        })
        #expect(all.payload[ObservationPayload.buildPhony] == .bool(true))
        let app = try #require(observed.first {
            $0.payload[ObservationPayload.buildTarget] == .string("app")
        })
        #expect(app.payload[ObservationPayload.buildPhony] == nil)
    }

    // MARK: - CI workflows

    @Test func claimsWorkflowFilesOnlyUnderGithubWorkflows() {
        let extractor = BuildExtractor()
        #expect(extractor.claims(file: file(".github/workflows/ci.yml")))
        #expect(extractor.claims(file: file(".github/workflows/deploy.yaml")))
        #expect(!extractor.claims(file: file(".github/dependabot.yml")))
        #expect(!extractor.claims(file: file("config/pipeline.yml")))
    }

    /// The literal fact is the command line a workflow runs. Which
    /// lane it names is resolution's problem.
    @Test func readsFastlaneInvocationsFromWorkflows() throws {
        let observed = try observations("""
            name: Deploy
            jobs:
              beta:
                steps:
                  - run: bundle exec fastlane ios beta
                  # - run: fastlane ios commented_out
                  - run: echo done
            """, path: ".github/workflows/deploy.yml")
        #expect(observed.count == 1)
        let invocation = try #require(observed.first)
        #expect(invocation.kind == .ciInvocation)
        #expect(invocation.payload[ObservationPayload.ciCommand]
                == .string("bundle exec fastlane ios beta"))
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

    private func steps(_ observations: [Observation], of target: String) -> [String] {
        for observation in observations {
            guard case .string(let name)? = observation.payload[ObservationPayload.buildTarget],
                  name == target,
                  case .array(let values)? = observation.payload[ObservationPayload.buildSteps]
            else { continue }
            return values.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        return []
    }

    /// A recipe is a sequence, so order is the fact. Prefixes that
    /// change echoing or error handling are stripped; what runs is
    /// what is recorded.
    @Test func readsRecipesInOrder() throws {
        let observed = try observations("""
            build:
            \t@echo building
            \t-rm -f stale.o
            \tclang -o app main.c
            """, path: "Makefile")
        #expect(steps(observed, of: "build")
                == ["echo building", "rm -f stale.o", "clang -o app main.c"])
    }

    /// Make gives every target on a rule line the same recipe.
    @Test func aMultiTargetRuleSharesItsRecipe() throws {
        let observed = try observations("""
            debug release: main.c
            \tclang -o $@ main.c
            """, path: "Makefile")
        #expect(steps(observed, of: "debug") == ["clang -o $@ main.c"])
        #expect(steps(observed, of: "release") == ["clang -o $@ main.c"])
    }

    @Test func aTargetWithNoRecipeReportsNone() throws {
        let observed = try observations("all: build\n", path: "Makefile")
        #expect(steps(observed, of: "all").isEmpty)
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

    /// A lane's steps are what it runs, in order — sub-lane calls
    /// included, since from the lane's side they are just steps. Ruby
    /// control flow is not.
    @Test func readsLaneStepsInOrder() throws {
        let observed = try observations("""
            lane :beta do
              setup
              build_app(scheme: "App")
              if ENV["CI"]
                upload_to_testflight
              end
            end

            lane :setup do
              cocoapods
            end
            """, path: "fastlane/Fastfile")
        #expect(steps(observed, of: "beta")
                == ["setup", "build_app", "upload_to_testflight"])
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
