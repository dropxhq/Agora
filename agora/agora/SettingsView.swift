import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Backend 与 Server URL 请在主窗口左侧侧边栏中管理。")
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .formStyle(.grouped)
#if os(macOS)
        .frame(width: 400, height: 120)
#endif
    }
}
