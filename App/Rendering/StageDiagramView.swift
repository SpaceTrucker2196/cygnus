import SwiftUI
import CygnusKit

// The converge loop as a horizontal pipeline of stage cards joined by
// chevrons. Native views (not the force-directed Canvas): the loop is
// small and strictly ordered, so hover/click come for free.

struct StageDiagramView: View {
    let pipeline: ConvergePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pipeline.sourcePath)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                        StageCard(step: step)
                        if index < pipeline.steps.count - 1 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.secondary)
                                .padding(.top, 26)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct StageCard: View {
    let step: ConvergeStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(step.index)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                Text(step.title).font(.subheadline.weight(.semibold))
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 170, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .help(step.detail)
    }
}
