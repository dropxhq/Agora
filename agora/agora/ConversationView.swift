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
                    isStreaming: vm.isStreaming,
                    isSendDisabled: store.agentCard(for: backend.id) == nil,
                    onSubmit: { submit(vm: vm) },
                    onStop: { vm.stop() },
                    onNewSession: { store.addSession(to: backend.id) }
                )
            }
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

        if SkillSlashCommand.isNewSessionCommand(input) {
            input = ""
            store.addSession(to: backend.id)
            return
        }

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
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(task.prompt)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if subTaskCount > 0 {
                Text("\(subTaskCount) 个子任务")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let skillId = task.skillId {
                HStack {
                    Spacer(minLength: 48)
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
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    @State private var expanded = false
    @State private var expandGeneration = 0

    private var hasProcess: Bool {
        !task.rounds.isEmpty
    }

    private var processLabel: String {
        if task.state == .working {
            return "处理中..."
        }
        let stepCount = max(task.rounds.count, 1)
        return "已完成 \(stepCount) 步骤"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasProcess {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        expanded.toggle()
                        if expanded {
                            expandGeneration += 1
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.subheadline)
                        Text(processLabel)
                            .font(.subheadline)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(task.rounds.indices, id: \.self) { i in
                            RoundView(round: task.rounds[i], expandGeneration: expandGeneration)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                }
            }

            if let summary = task.summary {
                MarkdownText(content: summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    var expandGeneration: Int = 0
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
        .onChange(of: expandGeneration) { _, _ in
            toolsExpanded = true
        }
        .onAppear {
            if expandGeneration > 0 {
                toolsExpanded = true
            }
        }
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
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)

                reasoningLabel(text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reasoningLabel(_ text: String) -> Text {
        let body = Text(text)
        guard hasTools else { return body }
        let chevron = Text(Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        return body + Text(" ") + chevron
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(toolPairs.enumerated()), id: \.offset) { _, pair in
                ToolCallResultRow(
                    call: pair.call,
                    result: pair.result,
                    expandGeneration: expandGeneration
                )
            }
        }
        .padding(.leading, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolCallResultRow: View {
    let call: ToolCall?
    let result: ToolResult?
    var expandGeneration: Int = 0
    @State private var resultExpanded = false

    private var hasResult: Bool { result != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let call {
                Button {
                    guard hasResult else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        resultExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench")
                            .font(.caption)
                            .frame(width: 14, alignment: .center)
                        Text(call.name)
                            .font(.caption)
                        if hasResult {
                            Image(systemName: resultExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasResult)
            }

            if let result, call == nil || resultExpanded {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "tray")
                        .font(.caption)
                        .frame(width: 14, alignment: .center)
                        .padding(.top, 1)
                    Text(result.result)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: expandGeneration) { _, _ in
            if hasResult {
                resultExpanded = true
            }
        }
        .onAppear {
            if expandGeneration > 0, hasResult {
                resultExpanded = true
            }
        }
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
