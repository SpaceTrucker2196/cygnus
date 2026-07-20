import SwiftUI
import AppKit
import CygnusKit

struct SettingsView: View {
    private var engineDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cygnus/engine")
    }

    var body: some View {
        Form {
            Section("Engine Data") {
                LabeledContent("Location") {
                    Text(engineDirectory.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([engineDirectory])
                }
            }
            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String ?? "0.1")
                LabeledContent("Analysis", value: "On-device only. No network access.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
