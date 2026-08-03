import SwiftUI
import CygnusKit

// Name a migration between two modules and watch where it actually
// stands. The pair is chosen here rather than guessed anywhere: which
// modules replace which is knowledge a person has and the graph does
// not.

struct MigrationFrontView: View {
    @Environment(WorkspaceStore.self) private var store
    let snapshot: GraphSnapshot

    private var modules: [GraphSnapshot.Node] {
        GraphScene.migratableModules(in: snapshot)
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            if modules.count < 2 {
                Text("A migration needs two modules to name. This repository "
                     + "charts fewer than two.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Migrating from → to").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    modulePicker($store.migrationFrom, label: "From module")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    modulePicker($store.migrationTo, label: "To module")
                }
                summary
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
        .accessibilityIdentifier("graph.migration")
    }

    private func modulePicker(_ selection: Binding<String?>, label: String) -> some View {
        Picker(label, selection: selection) {
            Text("—").tag(String?.none)
            ForEach(modules) { module in
                Text(module.label).tag(String?.some(module.id))
            }
        }
        .labelsHidden()
        .frame(width: 120)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var summary: some View {
        if let front = store.migrationFront(in: snapshot) {
            if let progress = front.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress) {
                        Text("\(Int(progress * 100))% moved").font(.caption)
                    }
                    row("Migrated", front.migrated, .green)
                    row("Straddling", front.straddling, .orange)
                    row("Not migrated", front.remaining, .red)
                    if front.straddling > 0 {
                        // The straddlers are the work: a file on both
                        // sides is where the migration is unfinished,
                        // not merely unstarted.
                        Text("\(front.straddling) file\(front.straddling == 1 ? "" : "s") "
                             + "use both — that is the remaining work.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if front.remaining == 0 {
                        Text("Nothing left on the old module. It can go.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("graph.migrationSummary")
            } else {
                Text("No file imports either module.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Pick both ends to see where the migration stands.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label.lowercased())").font(.caption)
        }
        .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}
