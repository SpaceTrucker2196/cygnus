import Foundation
import Observation
import CygnusEngine

// The app's hard memory ceiling. Cygnus holds the whole graph in
// memory and parses syntax trees to build it; a large or pathological
// repo could otherwise grow the process until macOS swaps itself to a
// standstill. The governor samples the real process footprint and
// enforces a fixed cap: analysis is refused while critical, and the
// live preview is shed under pressure. Views observe it for a readout.

@MainActor
@Observable
public final class MemoryGovernor {
    /// Hard ceiling. Analysis will not start above this, and callers
    /// shed retained state as it's approached.
    public let limitBytes: UInt64

    /// Most recent process footprint sample (`phys_footprint`).
    public private(set) var usedBytes: UInt64 = 0

    /// Fraction of the limit in use, clamped to [0, 1] for meters.
    public var fraction: Double {
        guard limitBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(limitBytes))
    }

    /// At/above the hard cap: refuse new work, shed what we can.
    public var isCritical: Bool { usedBytes >= limitBytes }

    /// Nearing the cap (≥ 85%): stop retaining optional state (live
    /// preview) so headroom is spent on the committed result, not the
    /// courtesy render.
    public var isHigh: Bool { usedBytes >= (limitBytes / 100) * 85 }

    /// e.g. "2.1 / 5.0 GB".
    public var summary: String {
        let gb = { (b: UInt64) in Double(b) / 1_073_741_824 }
        return String(format: "%.1f / %.1f GB", gb(usedBytes), gb(limitBytes))
    }

    private var sampler: Task<Void, Never>?

    /// Default cap is 5 GB. `CYGNUS_MEMORY_LIMIT_MB` overrides it (0
    /// disables the meter but never the sampling).
    public init(limitBytes: UInt64 = 5 * 1024 * 1024 * 1024) {
        if let mb = ProcessInfo.processInfo.environment["CYGNUS_MEMORY_LIMIT_MB"]
            .flatMap({ UInt64($0) }), mb > 0 {
            self.limitBytes = mb * 1024 * 1024
        } else {
            self.limitBytes = limitBytes
        }
        refresh()
    }

    /// Take one footprint sample now. Cheap; call before a gating
    /// decision so it isn't made on a stale reading.
    public func refresh() {
        if let bytes = MemoryFootprint.currentBytes() { usedBytes = bytes }
    }

    /// Begin periodic sampling so the UI meter tracks live. Idempotent.
    /// The loop holds only a weak reference, so it ends on its own once
    /// the governor is released.
    public func startSampling(interval: Duration = .seconds(1)) {
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
