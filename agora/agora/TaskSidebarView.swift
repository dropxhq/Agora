import SwiftUI

struct TaskSidebarView: View {
    let vm: ConversationVM
    var onCollapse: () -> Void = {}

    private var sortedTasks: [AITask] {
        vm.tasks.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
                Text("\(vm.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Button(action: onCollapse) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("收起边栏")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if vm.tasks.isEmpty {
                ContentUnavailableView {
                    Label("暂无 Task", systemImage: "tray")
                } description: {
                    Text("发送消息后将在此列出 A2A 任务")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { vm.selectedTaskId },
                    set: { if let id = $0 { vm.selectTask(id) } }
                )) {
                    ForEach(sortedTasks) { task in
                        TaskRow(task: task)
                            .tag(task.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
        .background(.background)
    }
}

private struct TaskRow: View {
    let task: AITask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                    .font(.caption)
                Text(task.promptPreview)
                    .font(.callout)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(stateLabel)
                    .font(.caption2)
                    .foregroundStyle(stateColor)
                if !task.rounds.isEmpty {
                    Text("\(task.rounds.count) 轮")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(task.taskIdSuffix)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
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
