import SwiftUI

struct ConversationView: View {
    let store: WorkspaceStore
    let session: Session
    let backend: Backend
    var onEditBackend: () -> Void = {}

    @State private var input = ""

    private var vm: ConversationVM {
        store.vm(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage = vm.errorMessage {
                            ConnectionErrorBanner(message: errorMessage, onOpenSettings: onEditBackend)
                        }
                        if !vm.rounds.isEmpty || vm.summary != nil {
                            TurnView(vm: vm)
                                .id("turn")
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.rounds.count) { _, _ in
                    proxy.scrollTo("turn", anchor: .bottom)
                }
            }

            Divider()

            HStack {
                TextField("输入问题...", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("发送", action: submit)
                    .disabled(input.isEmpty || vm.state == .working)
            }
            .padding()
        }
        .navigationTitle(session.title)
        .modifier(AgoraInlineNavigationTitleModifier())
        .onAppear { bindVM() }
        .onChange(of: session.id) { _, _ in bindVM() }
    }

    private func bindVM() {
        vm.onChange = { [sessionId = session.id] in
            store.persistSnapshot(for: sessionId)
        }
    }

    private func submit() {
        guard !input.isEmpty else { return }
        let text = input
        input = ""

        if session.title == "新会话" {
            let title = text.count > 24 ? String(text.prefix(24)) + "…" : text
            store.renameSession(session, title: title)
        }

        let url = URL(string: backend.serverURL) ?? URL(string: "http://localhost:8000")!
        vm.send(text: text, client: A2AClient(baseURL: url), contextId: session.contextId)
    }
}

struct TurnView: View {
    let vm: ConversationVM
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.rounds.indices, id: \.self) { i in
                        RoundView(round: vm.rounds[i], index: i + 1)
                    }
                }
                .padding(.leading, 4)
            } label: {
                Label(
                    vm.state == .working ? "执行中..." : "执行过程",
                    systemImage: vm.state == .working ? "circle.dotted" : "checkmark.circle"
                )
                .foregroundStyle(vm.state == .working ? .orange : .secondary)
            }

            if let summary = vm.summary {
                Text(summary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct ConnectionErrorBanner: View {
    let message: String
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("无法连接后端", systemImage: "wifi.slash")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("编辑 Backend", action: onOpenSettings)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RoundView: View {
    let round: Round
    let index: Int
    @State private var resultsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Round \(index)").font(.caption).foregroundStyle(.tertiary)

            if let r = round.reasoning {
                Label(r, systemImage: "bubble.left.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(round.toolCalls) { tc in
                Label("\(tc.name)(\(tc.argsPreview))", systemImage: "wrench.fill")
                    .font(.callout.monospaced())
                    .foregroundStyle(.blue)
            }

            if !round.toolResults.isEmpty {
                DisclosureGroup(isExpanded: $resultsExpanded) {
                    ForEach(round.toolResults) { tr in
                        HStack(alignment: .top) {
                            Image(systemName: tr.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(tr.ok ? .green : .red)
                            Text(tr.result).font(.caption.monospaced())
                        }
                    }
                } label: {
                    Label("工具结果 (\(round.toolResults.count))", systemImage: "tray.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AgoraInlineNavigationTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
#else
        content
#endif
    }
}
