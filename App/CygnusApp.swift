import SwiftUI
import CygnusKit

@main
struct CygnusApp: App {
    @State private var store = CygnusApp.makeStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environment(store)
                .task { CygnusApp.seedIfRequested(store) }
        }
        // Corrupted window-restoration state (e.g. after a force-
        // killed instance) must never leave the app running with no
        // window: always present, never restore.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        Settings {
            SettingsView()
        }
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
