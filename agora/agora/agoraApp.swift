import SwiftUI

@main
struct agoraApp: App {
    var body: some Scene {
        WindowGroup {
            ConversationView()
        }
#if os(macOS)
        Settings {
            SettingsView()
        }
#endif
    }
}
