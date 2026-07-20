import SwiftUI
import CygnusKit

@main
struct CygnusApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environment(store)
        }
        Settings {
            SettingsView()
        }
    }
}
