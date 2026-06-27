import SwiftUI

struct ConversationView: View {
    let store: WorkspaceStore
    let session: Session
    let backend: Backend
    var onEditBackend: () -> Void = {}

    @State private var input = ""
    @State private var isTaskSidebarVisible = true

    private var vm: ConversationVM {
        store.vm(for: session.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationPanel

            if isTaskSidebarVisible {
                Divider()
                TaskSidebarView(vm: vm) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTaskSidebarVisible = false
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTaskSidebarVisible)
        .navigationTitle(session.title)
        .modifier(AgoraInlineNavigationTitleModifier())
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTaskSidebarVisible.toggle()
                    }
                } label: {
                    Label("Tasks", systemImage: "sidebar.right")
                }
                .help(isTaskSidebarVisible ? "收起 Task 边栏" : "展开 Task 边栏")
            }
        }
        .onAppear { bindVM() }
        .onChange(of: session.id) { _, _ in
            bindVM()
            input = ""
        }
    }

    private var conversationPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let task = vm.selectedTask {
                            Text(task.prompt)
                                .font(.body)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }

                        if let errorMessage = vm.errorMessage {
                            ConnectionErrorBanner(message: errorMessage, onOpenSettings: onEditBackend)
                        }

                        if vm.selectedTask == nil && vm.tasks.isEmpty {
                            ContentUnavailableView {
                                Label("开始对话", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("输入问题发送，Task 将出现在右侧边栏")
                            }
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else if !vm.rounds.isEmpty || vm.summary != nil || vm.state == .working {
                            TurnView(vm: vm)
                                .id("turn-\(vm.selectedTaskId ?? "")")
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.rounds.count) { _, _ in
                    proxy.scrollTo("turn-\(vm.selectedTaskId ?? "")", anchor: .bottom)
                }
                .onChange(of: vm.selectedTaskId) { _, _ in
                    proxy.scrollTo("turn-\(vm.selectedTaskId ?? "")", anchor: .bottom)
                }
            }

            HStack {
                GlassInputBar(
                    text: $input,
                    placeholder: "输入问题...",
                    isSendDisabled: vm.isStreaming,
                    onSubmit: submit
                )
            }

            Button {
                store.addSession(to: backend.id)
            } label: {
                Label("新建会话", systemImage: "plus.message")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
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
