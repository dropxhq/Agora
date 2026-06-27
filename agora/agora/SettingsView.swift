import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL") var serverURL = "http://localhost:8000"

    var body: some View {
        Form {
            Section("后端配置") {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
#if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
#endif
            }
        }
        .formStyle(.grouped)
#if os(macOS)
        .frame(width: 400, height: 120)
#endif
    }
}
