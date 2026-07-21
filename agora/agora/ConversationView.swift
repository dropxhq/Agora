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

    private var agentSkills: [AgentSkill] {
        store.agentCard(for: backend.id)?.skills ?? []
    }

    var body: some View {
        @Bindable var vm = store.vm(for: session.id)

        conversationPanel(vm: vm)
            .navigationTitle(session.title)
            .modifier(AgoraInlineNavigationTitleModifier())
            .onAppear {
                bindVM()
                store.loadAgentCard(for: backend)
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
                .onChange(of: vm.thinking.count) { _, _ in
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
        proxy.scrollTo("turn-\(rootTask.id)", anchor: .bottom)
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
    let errorMessage: String?
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainTaskHeader(task: rootTask)

            if let errorMessage {
                ConnectionErrorBanner(message: errorMessage, onOpenSettings: onOpenSettings)
            }

            TurnView(task: rootTask)
                .id("turn-\(rootTask.id)")
        }
    }
}

struct MainTaskHeader: View {
    let task: AITask

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

struct TurnView: View {
    let task: AITask
    @State private var expanded = false
    @State private var expandGeneration = 0

    private var hasProcess: Bool {
        task.hasThinking
    }

    private var processLabel: String {
        if task.state == .working {
            return "处理中..."
        }
        let stepCount = max(task.thinking.count, 1)
        return "已完成 \(stepCount) 步"
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
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(task.thinking) { item in
                            ThinkingItemView(item: item, expandGeneration: expandGeneration)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                }
            }

            if task.hasResultContent {
                let live = task.summaryBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !task.resultBlocks.isEmpty || !live.isEmpty {
                    ResultBlocksView(
                        blocks: task.resultBlocks,
                        liveMarkdown: live.isEmpty ? nil : live
                    )
                } else if let summary = task.summary {
                    MarkdownText(content: summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinkingItemView: View {
    let item: ThinkingItem
    var expandGeneration: Int = 0

    var body: some View {
        switch item {
        case .reasoning(_, let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)
                MarkdownText(content: text, style: .process)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
        case .toolCall(let call):
            ToolCallRow(call: call, expandGeneration: expandGeneration)
        }
    }
}

private struct ToolCallRow: View {
    let call: ToolCall
    var expandGeneration: Int = 0
    @State private var detailsExpanded = false

    private var hasDetails: Bool {
        call.result != nil || !call.args.isEmpty || !(call.desc?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasDetails else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    detailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: call.tool.systemImage)
                        .font(.caption)
                        .frame(width: 14, alignment: .center)
                    Text(call.tool.displayName)
                        .font(.caption.monospaced())
                    if let desc = call.desc, !desc.isEmpty, !detailsExpanded {
                        Text("· \(desc)")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                    if hasDetails {
                        Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetails)

            if detailsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let desc = call.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !call.args.isEmpty {
                        Text(call.argsPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let result = call.result {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: result.ok ? "tray" : "exclamationmark.triangle")
                                .font(.caption)
                                .frame(width: 14, alignment: .center)
                                .padding(.top, 1)
                            Text(result.result)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: expandGeneration) { _, _ in
            if hasDetails {
                detailsExpanded = true
            }
        }
        .onAppear {
            if expandGeneration > 0, hasDetails {
                detailsExpanded = true
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

private struct AgoraInlineNavigationTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
#else
        content
#endif
    }
}
