import SwiftUI

@main
struct agoraApp: App {
    @AppStorage("serverURL") var serverURL = "http://localhost:8000"

    var body: some Scene {
        WindowGroup {
            ConversationView(client: A2AClient(baseURL: URL(string: serverURL) ?? URL(string: "http://localhost:8000")!))
        }
#if os(macOS)
        Settings {
            SettingsView()
        }
#endif
    }
}
