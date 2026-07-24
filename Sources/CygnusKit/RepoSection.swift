import Foundation

// The ops sections a selected repo can show. Orthogonal to the
// code-graph analysis state: only `.codeGraph` consumes that; the four
// factory sections read the provider layer.

public enum RepoSection: String, CaseIterable, Sendable {
    case dashboard
    case workflow
    case issues
    case docs
    case codeGraph

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .workflow: "Workflow"
        case .issues: "Issues"
        case .docs: "Docs"
        case .codeGraph: "Code Graph"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .workflow: "arrow.trianglehead.branch"
        case .issues: "checklist"
        case .docs: "doc.text"
        case .codeGraph: "point.3.connected.trianglepath.dotted"
        }
    }
}
