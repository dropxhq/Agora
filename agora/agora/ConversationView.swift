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

    private var agentSkills: [AgentSkill] {
        store.agentCard(for: backend.id)?.skills ?? []
    }

    var body: some View {
        @Bindable var vm = store.vm(for: session.id)

        HStack(spacing: 0) {
            conversationPanel(vm: vm)

            if isTaskSidebarVisible && vm.hasSubTasks {
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
        .animation(.easeInOut(duration: 0.2), value: vm.hasSubTasks)
        .navigationTitle(session.title)
        .modifier(AgoraInlineNavigationTitleModifier())
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if vm.hasSubTasks {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isTaskSidebarVisible.toggle()
                        }
                    } label: {
                        Label("子任务", systemImage: "sidebar.right")
                    }
                    .help(isTaskSidebarVisible ? "收起子任务边栏" : "展开子任务边栏")
                }
            }
        }
        .onAppear {
            bindVM()
            store.loadAgentCard(for: backend)
            if vm.hasSubTasks {
                isTaskSidebarVisible = true
            }
        }
        .onChange(of: vm.hasSubTasks) { _, hasSubTasks in
            if hasSubTasks {
                isTaskSidebarVisible = true
            }
        }
        .onChange(of: session.id) { _, _ in
            bindVM()
            input = ""
        }
    }

    private func conversationPanel(vm: ConversationVM) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage = vm.errorMessage, vm.rootTasks.isEmpty {
                            ConnectionErrorBanner(message: errorMessage, onOpenSettings: onEditBackend)
                        }

                        if vm.rootTasks.isEmpty {
                            AgentCardEmptyStateView(
                                backend: backend,
                                store: store,
                                onEditBackend: onEditBackend
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            ForEach(vm.rootTasks, id: \.id) { rootTask in
                                TaskConversationBlock(
                                    rootTask: rootTask,
                                    subTasks: vm.subTasks(for: rootTask.id),
                                    errorMessage: rootTask.id == vm.mainTask?.id ? vm.errorMessage : nil,
                                    onOpenSettings: onEditBackend
                                )
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.rootTasks.count) { _, _ in
                    scrollToLatest(proxy: proxy, vm: vm)
                }
                .onChange(of: vm.rounds.count) { _, _ in
                    scrollToLatest(proxy: proxy, vm: vm)
                }
                .onChange(of: vm.selectedSubTaskId) { _, _ in
                    scrollToLatest(proxy: proxy, vm: vm)
                }
                .onChange(of: vm.summary) { _, _ in
                    scrollToLatest(proxy: proxy, vm: vm)
                }
            }

            HStack {
                GlassInputBar(
                    text: $input,
                    placeholder: agentSkills.isEmpty ? "输入问题..." : "输入问题，或 / 选择 Skill…",
                    skills: agentSkills,
                    isSendDisabled: vm.isStreaming || store.agentCard(for: backend.id) == nil,
                    onSubmit: { submit(vm: vm) }
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

    private func scrollToLatest(proxy: ScrollViewProxy, vm: ConversationVM) {
        guard let rootTask = vm.mainTask else { return }
        let subs = vm.subTasks(for: rootTask.id)
        if let subTask = subs.last {
            proxy.scrollTo("subtask-\(subTask.id)", anchor: .bottom)
        } else {
            proxy.scrollTo("turn-\(rootTask.id)", anchor: .bottom)
        }
    }

    private func bindVM() {
        vm.onChange = { [sessionId = session.id] in
            store.persistSnapshot(for: sessionId)
        }
    }

    private func submit(vm: ConversationVM) {
        guard !input.isEmpty else { return }
        let outgoing = SkillSlashCommand.prepareOutgoing(from: input, skills: agentSkills)
        input = ""

        if session.title == "新会话" {
            let titleSource = outgoing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = titleSource.count > 24 ? String(titleSource.prefix(24)) + "…" : titleSource
            store.renameSession(session, title: title)
        }

        vm.send(
            text: outgoing.text,
            client: store.a2aClient(for: backend),
            contextId: session.contextId,
            skill: outgoing.skill
        )
    }
}

struct TaskConversationBlock: View {
    let rootTask: AITask
    let subTasks: [AITask]
    let errorMessage: String?
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainTaskHeader(task: rootTask, subTaskCount: subTasks.count)

            if let errorMessage {
                ConnectionErrorBanner(message: errorMessage, onOpenSettings: onOpenSettings)
            }

            if subTasks.isEmpty {
                TurnView(task: rootTask)
                    .id("turn-\(rootTask.id)")
            } else {
                ForEach(subTasks) { subTask in
                    SubTaskSection(task: subTask)
                        .id("subtask-\(subTask.id)")
                }
            }
        }
    }
}

struct MainTaskHeader: View {
    let task: AITask
    let subTaskCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text("主任务")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if subTaskCount > 0 {
                    Text("\(subTaskCount) 个子任务")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(stateLabel)
                    .font(.caption2)
                    .foregroundStyle(stateColor)
            }

            Text(task.prompt)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let skillId = task.skillId {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                    Text("/\(skillId)")
                        .font(.caption.monospaced())
                    if let skillName = task.skillName {
                        Text(skillName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.purple.opacity(0.1), in: Capsule())
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stateIcon: String {
        switch task.state {
        case .working: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .idle: return "circle"
        }
    }

    private var stateColor: Color {
        switch task.state {
        case .working: return .orange
        case .completed: return .green
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var stateLabel: String {
        switch task.state {
        case .working: return "执行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .idle: return "空闲"
        }
    }
}

struct SubTaskSection: View {
    let task: AITask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let index = task.subtaskIndex {
                Text("子任务 \(index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            TurnView(task: task)
        }
    }
}

struct TurnView: View {
    let task: AITask
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.rounds.indices, id: \.self) { i in
                        RoundView(round: task.rounds[i])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 4)
            } label: {
                Label(
                    task.state == .working ? "执行中..." : "执行过程",
                    systemImage: task.state == .working ? "circle.dotted" : "checkmark.circle"
                )
                .foregroundStyle(task.state == .working ? .orange : .secondary)
            }

            if let summary = task.summary {
                MarkdownText(content: summary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var toolsExpanded = false

    private var hasTools: Bool {
        !round.toolCalls.isEmpty || !round.toolResults.isEmpty
    }

    private var toolPairs: [(call: ToolCall?, result: ToolResult?)] {
        let count = max(round.toolCalls.count, round.toolResults.count)
        return (0..<count).map { i in
            (
                i < round.toolCalls.count ? round.toolCalls[i] : nil,
                i < round.toolResults.count ? round.toolResults[i] : nil
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let r = round.reasoning {
                reasoningRow(r)
            }

            if shouldShowTools {
                toolsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowTools: Bool {
        guard hasTools else { return false }
        // 无 reasoning 时直接展示工具；有 reasoning 时由 > 控制，默认收起
        return round.reasoning == nil || toolsExpanded
    }

    private func reasoningRow(_ text: String) -> some View {
        Button {
            guard hasTools else { return }
            withAnimation(.snappy(duration: 0.2)) {
                toolsExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                MarkdownText(content: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                if hasTools {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(toolsExpanded ? 90 : 0))
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasTools)
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(toolPairs.enumerated()), id: \.offset) { _, pair in
                if let call = pair.call {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wrench.fill")
                            .font(.callout)
                            .foregroundStyle(.blue)
                        Text(call.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let result = pair.result {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(result.ok ? .green : .red)
                        Text(result.result)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
