import SwiftUI

@main
struct agoraApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
#if os(macOS)
        Settings {
            SettingsView()
        }
#endif
    }
}
