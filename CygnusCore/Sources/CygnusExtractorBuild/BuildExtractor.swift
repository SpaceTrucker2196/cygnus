import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders

// Build files as evidence. *Kill It With Fire* calls this overgrowth:
// "a particular type of coupling between the software and the layers
// of abstraction making up the platform on which it runs" — the
// auxiliary software that must be migrated before the application
// can be. It is part of the system, and it was not in the graph.
//
// Emits literal facts only: this target exists, and this is one thing
// it is written to need. Whether that name resolves to a real file is
// resolution's problem.

public struct BuildExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "build-files", version: "0.1.0")

    public init() {}

    /// Make and fastlane, by the names those tools actually look for.
    public func claims(file: SnapshotFile) -> Bool {
        Self.system(forPath: file.path) != nil
    }

    static func system(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if ["Makefile", "makefile", "GNUmakefile"].contains(name) { return "make" }
        if path.hasSuffix(".mk") { return "make" }
        // Only fastlane's own Fastfile — a file called Fastfile
        // somewhere unrelated is not evidence about the build.
        if name == "Fastfile", path.contains("fastlane/") || path == "Fastfile" {
            return "fastlane"
        }
        return nil
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        guard let system = Self.system(forPath: file.path) else { return [] }
        let text = String(decoding: content, as: UTF8.self)
        return switch system {
        case "make": makeObservations(text, file: file)
        default: fastlaneObservations(text, file: file)
        }
    }

    private func makeObservations(_ text: String, file: SnapshotFile) -> [Observation] {
        MakefileRules.parse(text).enumerated().flatMap { order, rule in
            observations(target: rule.target, dependencies: rule.prerequisites,
                         steps: rule.recipe, order: order, system: "make", file: file)
        }
    }

    private func fastlaneObservations(_ text: String, file: SnapshotFile) -> [Observation] {
        FastfileLanes.parse(text).enumerated().flatMap { order, lane in
            observations(target: lane.name, dependencies: lane.calls,
                         steps: lane.steps, order: order, system: "fastlane", file: file)
        }
    }

    /// One observation asserting the target exists, then one per
    /// dependency. Split so a target with nothing to depend on is
    /// still a fact, and so provenance points at the exact statement
    /// that supports each edge.
    private func observations(target: String, dependencies: [String],
                              steps: [String] = [], order: Int = 0, system: String,
                              file: SnapshotFile) -> [Observation] {
        var payload: [String: PropertyValue] = [
            ObservationPayload.buildTarget: .string(target),
            ObservationPayload.buildSystem: .string(system),
            ObservationPayload.buildOrder: .int(Int64(order)),
        ]
        // Order carries the meaning, so the steps ride as an ordered
        // array on the target's existence observation rather than as
        // one observation each — a set of commands would not say what
        // the target does.
        if !steps.isEmpty {
            payload[ObservationPayload.buildSteps] = .array(steps.map { .string($0) })
        }
        var result = [Observation(kind: .buildRule, file: SourceAnchor(path: file.path, blob: file.blob, range: nil),
                                  payload: payload, extractor: identity)]
        for dependency in dependencies {
            payload[ObservationPayload.buildDependency] = .string(dependency)
            result.append(Observation(kind: .buildRule,
                                      file: SourceAnchor(path: file.path, blob: file.blob, range: nil),
                                      payload: payload, extractor: identity))
        }
        return result
    }
}
