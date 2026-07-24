import Foundation

// Resource ceiling for one index run. The extractor stage is the
// pipeline's memory peak — each in-flight file holds a full syntax
// tree (SwiftSyntax / tree-sitter), the heaviest allocation cygnus
// makes — so peak memory is roughly `maxConcurrentExtractions` trees
// at once. Left unbounded (one task per file), a large repo on a
// many-core machine parses hundreds of trees simultaneously and can
// exhaust system memory. These limits keep that peak flat.

public struct IndexLimits: Sendable {
    /// Maximum files parsed at once. Peak extractor memory scales with
    /// this, not with repository size.
    public let maxConcurrentExtractions: Int

    /// When the process footprint climbs above this, extraction
    /// serializes (window shrinks to one) until it recovers — a soft
    /// brake below the app's hard cap, leaving headroom for the UI and
    /// renderer. `nil` disables memory-based throttling.
    public let softMemoryLimitBytes: UInt64?

    public init(maxConcurrentExtractions: Int, softMemoryLimitBytes: UInt64?) {
        self.maxConcurrentExtractions = max(1, maxConcurrentExtractions)
        self.softMemoryLimitBytes = softMemoryLimitBytes
    }

    /// Default budget: parallel across cores but capped so a 24-core
    /// machine doesn't hold 24 syntax trees, with a 3.5 GB soft brake
    /// that sits under the app's 5 GB hard ceiling. Both knobs honour
    /// env overrides so the CLI can tune without a rebuild.
    public static var `default`: IndexLimits {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let concurrency = env("CYGNUS_MAX_EXTRACT_CONCURRENCY").map { max(1, $0) }
            ?? min(cores, 6)
        let softMB = env("CYGNUS_SOFT_MEMORY_MB") ?? 3584
        let soft: UInt64? = softMB > 0 ? UInt64(softMB) * 1024 * 1024 : nil
        return IndexLimits(maxConcurrentExtractions: concurrency, softMemoryLimitBytes: soft)
    }

    private static func env(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init)
    }

    /// Current window width: the full budget normally, one under
    /// memory pressure so we stop adding trees while already high.
    func window() -> Int {
        if let soft = softMemoryLimitBytes,
           let used = MemoryFootprint.currentBytes(), used > soft {
            return 1
        }
        return maxConcurrentExtractions
    }
}
