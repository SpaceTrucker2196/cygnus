import SwiftUI
import CygnusKit

// Semantic status → colour + symbol for CI runs, checks, and converge
// steps. Shaped like the graph's KindStyle. Deliberately NOT reusing
// GraphPalette (whose hues are categorical, not pass/fail).

enum FactoryStatus: Sendable {
    case success, failure, running, queued, cancelled, skipped, neutral

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .running: .blue
        case .queued: .orange
        case .cancelled: .gray
        case .skipped: .secondary
        case .neutral: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .running: "circle.dotted"
        case .queued: "clock"
        case .cancelled: "slash.circle"
        case .skipped: "minus.circle"
        case .neutral: "circle"
        }
    }

    var label: String {
        switch self {
        case .success: "Passed"
        case .failure: "Failed"
        case .running: "Running"
        case .queued: "Queued"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "—"
        }
    }

    /// Map a GitHub Actions run's (status, conclusion) pair.
    static func from(status: String, conclusion: String?) -> FactoryStatus {
        switch status.lowercased() {
        case "completed":
            switch (conclusion ?? "").lowercased() {
            case "success": return .success
            case "failure", "timed_out", "startup_failure": return .failure
            case "cancelled": return .cancelled
            case "skipped", "neutral": return .skipped
            default: return .neutral
            }
        case "in_progress": return .running
        case "queued", "waiting", "pending", "requested": return .queued
        default: return .neutral
        }
    }
}

extension WorkflowRun {
    var factoryStatus: FactoryStatus { .from(status: status, conclusion: conclusion) }
}

extension CheckRun {
    var factoryStatus: FactoryStatus { .from(status: status, conclusion: conclusion) }
}

/// A small colored status pill reused across the ops sections.
struct StatusBadge: View {
    let status: FactoryStatus
    var text: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text(text ?? status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
    }
}
