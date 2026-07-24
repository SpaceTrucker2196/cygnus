import Foundation

// Per-repo, per-dataset loading state for the ops sections. Each
// dataset loads on demand and refreshes independently, so a slow
// `gh issue list` never blocks the docs tree.

public enum Loadable<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public struct FactoryState: Sendable, Equatable {
    public var capabilities: Loadable<FactoryCapabilities> = .idle
    public var issues: Loadable<[Issue]> = .idle
    public var runs: Loadable<[WorkflowRun]> = .idle
    public var commits: Loadable<[CommitInfo]> = .idle
    public var metrics: Loadable<[MetricsRow]> = .idle
    public var ledger: Loadable<[LedgerRow]> = .idle
    public var converge: Loadable<ConvergePipeline?> = .idle
    public var docs: Loadable<DocTree> = .idle

    public init() {}

    /// Capabilities once detected, or `.empty` while unknown — views
    /// use this to gate sections.
    public var caps: FactoryCapabilities { capabilities.value ?? .empty }
}

/// The datasets a section needs loaded, so `ensureLoaded` fires only
/// what's required.
public enum FactoryDataset: Hashable, Sendable, CaseIterable {
    case capabilities, issues, runs, commits, metrics, ledger, converge, docs
}
