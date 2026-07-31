import SwiftUI
import CygnusKit

@main
struct CygnusApp: App {
    @State private var store = CygnusApp.makeStore()
    /// App-wide text size. Index into `textSizes`; persisted. macOS
    /// scales semantic-style text (.body/.caption/.headline…) from
    /// `.dynamicTypeSize`; the graph's own labels have their own slider.
    @AppStorage("textSizeIndex") private var textSizeIndex = 3

    private static let textSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
        .accessibility1, .accessibility2, .accessibility3,
    ]
    private static let defaultTextSize = 3   // .large
    private var textSize: DynamicTypeSize {
        Self.textSizes[min(max(textSizeIndex, 0), Self.textSizes.count - 1)]
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environment(store)
                .dynamicTypeSize(textSize)
                .task { CygnusApp.seedIfRequested(store) }
        }
        // Corrupted window-restoration state (e.g. after a force-
        // killed instance) must never leave the app running with no
        // window: always present, never restore.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            textSizeCommands
            helpCommands
        }
        Settings {
            SettingsView().dynamicTypeSize(textSize)
        }
        // The reference lives in its own window so it can sit beside
        // the app while you follow it.
        Window("Cygnus Help", id: Self.helpWindowID) {
            HelpView().dynamicTypeSize(textSize)
        }
        .defaultSize(width: 900, height: 620)
    }

    static let helpWindowID = "cygnus-help"

    /// Replaces the default Help item, which points at documentation
    /// that does not exist for this app.
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            HelpMenuButton()
        }
    }

    /// View → Text Size menu. ⌘= / ⌘- / ⌘0, plus a ⌘⇧+ alias for the
    /// habit of pressing shifted-plus (a Command-only shortcut won't
    /// match a literal "+" key, which needs Shift).
    private var textSizeCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { bumpTextSize(1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Bigger Text (+)") { bumpTextSize(1) }
                .keyboardShortcut("+", modifiers: [.command, .shift])
            Button("Smaller Text") { bumpTextSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Text Size") { textSizeIndex = Self.defaultTextSize }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// A view, not a bare Button: `openWindow` is an environment
    /// value, and `App` itself has no environment to read it from.
    private struct HelpMenuButton: View {
        @Environment(\.openWindow) private var openWindow
        var body: some View {
            Button("Cygnus Help") { openWindow(id: CygnusApp.helpWindowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private func bumpTextSize(_ delta: Int) {
        textSizeIndex = min(max(textSizeIndex + delta, 0), Self.textSizes.count - 1)
    }

    /// Normal launches use the container defaults. UI-test launches
    /// (`--uitest-seed-repo`) get an isolated store; seeding happens
    /// after the window is up (App-init side effects can suppress
    /// window creation entirely).
    @MainActor
    static func makeStore() -> WorkspaceStore {
        guard uitestMode else { return WorkspaceStore() }
        let base = uitestBase
        try? FileManager.default.removeItem(at: base)
        return WorkspaceStore(
            engine: WorkspaceGraphEngine(directory: base.appendingPathComponent("engine")),
            persistence: WorkspacePersistence(
                fileURL: base.appendingPathComponent("workspace.json")))
    }

    private static var uitestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-seed-repo")
    }

    private static var uitestBase: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cygnus-uitest")
    }

    /// Generate the fixture repo and register it — the real
    /// add→bookmark→analyze path, no open panel needed.
    @MainActor
    static func seedIfRequested(_ store: WorkspaceStore) {
        guard uitestMode, store.repos.isEmpty else { return }
        let repoRoot = uitestBase.appendingPathComponent("uitest-repo")
        do {
            for directory in ["Sources/FixtureCore", "Sources/FixtureApp"] {
                try FileManager.default.createDirectory(
                    at: repoRoot.appendingPathComponent(directory),
                    withIntermediateDirectories: true)
            }
            try "public struct Core { public func tick() {} }\n".write(
                to: repoRoot.appendingPathComponent("Sources/FixtureCore/Core.swift"),
                atomically: true, encoding: .utf8)
            try """
                import FixtureCore

                struct AppMain {
                    func run() -> Core { Core() }
                }
                """.write(
                    to: repoRoot.appendingPathComponent("Sources/FixtureApp/App.swift"),
                    atomically: true, encoding: .utf8)
        } catch {
            // Seeding failed; the UI test fails visibly on the
            // missing repo row.
        }
        store.addRepository(at: repoRoot)
    }
}
