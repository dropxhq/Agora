import Foundation
import Observation

@Observable
class ConversationVM {
    var tasks: [AITask] = []
    var selectedTaskId: String?
    var activeMainTaskId: String?
    var selectedSubTaskId: String?

    private var pendingPrompt: String?
    private var streamingTaskId: String?
    private var orchestratesSubTasks = false
    private let decoder = JSONDecoder()

    var onChange: (() -> Void)?

    var mainTask: AITask? {
        if let id = activeMainTaskId {
            return tasks.first { $0.id == id }
        }
        return rootTasks.last
    }

    var rootTasks: [AITask] {
        tasks.filter { !$0.isSubTask }
    }

    var subTasks: [AITask] {
        guard let main = mainTask else { return [] }
        return tasks
            .filter { $0.parentTaskId == main.id }
            .sorted { ($0.subtaskIndex ?? Int.max) < ($1.subtaskIndex ?? Int.max) }
    }

    var hasSubTasks: Bool { !subTasks.isEmpty }

    var displayTask: AITask? {
        if hasSubTasks {
            if let id = selectedSubTaskId {
                return subTasks.first { $0.id == id }
            }
            return subTasks.first
        }
        return mainTask
    }

    var selectedTask: AITask? { displayTask }

    var rounds: [Round] { displayTask?.rounds ?? [] }
    var summary: String? { displayTask?.summary }
    var state: TaskState { displayTask?.state ?? mainTask?.state ?? .idle }
    var errorMessage: String? { displayTask?.errorMessage ?? mainTask?.errorMessage }

    var isStreaming: Bool {
        tasks.contains { $0.state == .working }
    }

    func selectSubTask(_ id: String) {
        selectedSubTaskId = id
        notifyChange()
    }

    func selectTask(_ id: String) {
        if subTasks.contains(where: { $0.id == id }) {
            selectSubTask(id)
            return
        }
        selectedTaskId = id
        notifyChange()
    }

    func send(text: String, client: A2AClient, contextId: String) {
        let placeholderId = "main-\(UUID().uuidString)"
        let task = AITask(id: placeholderId, prompt: text, state: .working)
        tasks.append(task)
        activeMainTaskId = placeholderId
        selectedSubTaskId = nil
        selectedTaskId = placeholderId
        streamingTaskId = placeholderId
        orchestratesSubTasks = Self.isMultiTaskPrompt(text)
        pendingPrompt = text
        notifyChange()

        Task { @MainActor in
            do {
                let stream = client.sendStreamingMessage(text: text, contextId: contextId)
                for try await data in stream {
                    apply(data)
                }
                pendingPrompt = nil
                orchestratesSubTasks = false
            } catch {
                handleStreamError(error, serverURL: client.baseURL)
            }
        }
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            tasks: tasks.map { task in
                PersistedTask(
                    id: task.id,
                    prompt: task.prompt,
                    parentTaskId: task.parentTaskId,
                    subtaskIndex: task.subtaskIndex,
                    rounds: task.rounds.map { round in
                        PersistedRound(
                            reasoning: round.reasoning,
                            toolCalls: round.toolCalls.map {
                                PersistedToolCall(name: $0.name, args: $0.args)
                            },
                            toolResults: round.toolResults.map {
                                PersistedToolResult(name: $0.name, result: $0.result, ok: $0.ok)
                            }
                        )
                    },
                    summary: task.summary,
                    state: task.state.label,
                    errorMessage: task.errorMessage,
                    createdAt: task.createdAt
                )
            },
            selectedTaskId: selectedTaskId,
            activeMainTaskId: activeMainTaskId,
            selectedSubTaskId: selectedSubTaskId
        )
    }

    func restore(from snapshot: SessionSnapshot) {
        if let persistedTasks = snapshot.tasks, !persistedTasks.isEmpty {
            tasks = persistedTasks.map { restoreTask(from: $0) }
            activeMainTaskId = snapshot.activeMainTaskId ?? rootTasks.last?.id
            selectedSubTaskId = snapshot.selectedSubTaskId
            selectedTaskId = snapshot.selectedTaskId
            return
        }

        guard let legacyRounds = snapshot.rounds else {
            tasks = []
            activeMainTaskId = nil
            selectedSubTaskId = nil
            selectedTaskId = nil
            return
        }

        let task = AITask(id: UUID().uuidString, prompt: "历史任务", state: .idle)
        task.rounds = legacyRounds.map { persisted in
            let round = Round()
            round.reasoning = persisted.reasoning
            round.toolCalls = persisted.toolCalls.map {
                ToolCall(name: $0.name, args: $0.args)
            }
            round.toolResults = persisted.toolResults.map {
                ToolResult(name: $0.name, result: $0.result, ok: $0.ok)
            }
            return round
        }
        task.summary = snapshot.summary
        task.summaryBuffer = snapshot.summary ?? ""
        task.state = TaskState.from(label: snapshot.state ?? "idle")
        task.errorMessage = snapshot.errorMessage
        tasks = [task]
        activeMainTaskId = task.id
        selectedTaskId = task.id
    }

    private func restoreTask(from persisted: PersistedTask) -> AITask {
        let task = AITask(
            id: persisted.id,
            prompt: persisted.prompt,
            parentTaskId: persisted.parentTaskId,
            subtaskIndex: persisted.subtaskIndex,
            state: TaskState.from(label: persisted.state),
            createdAt: persisted.createdAt
        )
        task.rounds = persisted.rounds.map { persistedRound in
            let round = Round()
            round.reasoning = persistedRound.reasoning
            round.toolCalls = persistedRound.toolCalls.map {
                ToolCall(name: $0.name, args: $0.args)
            }
            round.toolResults = persistedRound.toolResults.map {
                ToolResult(name: $0.name, result: $0.result, ok: $0.ok)
            }
            return round
        }
        task.summary = persisted.summary
        task.summaryBuffer = persisted.summary ?? ""
        task.errorMessage = persisted.errorMessage
        return task
    }

    private func notifyChange() {
        onChange?()
    }

    @MainActor
    private func handleStreamError(_ error: Error, serverURL: URL) {
        let message = ConnectionErrorMessage.message(for: error, serverURL: serverURL)
        if let taskId = streamingTaskId, let task = tasks.first(where: { $0.id == taskId }) {
            task.errorMessage = message
            task.state = .failed
            refreshMainTaskState(for: task.parentTaskId ?? task.id)
        } else if let prompt = pendingPrompt {
            let task = AITask(id: UUID().uuidString, prompt: prompt, state: .failed)
            task.errorMessage = message
            tasks.append(task)
            activeMainTaskId = task.id
            selectedTaskId = task.id
        }
        pendingPrompt = nil
        streamingTaskId = nil
        orchestratesSubTasks = false
        notifyChange()
    }

    @MainActor
    private func apply(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        let payload = Self.streamPayloadData(from: data)

        if let t = try? decoder.decode(A2ATask.self, from: payload) {
            if orchestratesSubTasks {
                registerSubTask(t.id)
            } else {
                adoptServerTaskId(t.id)
                if tasks.first(where: { $0.id == t.id }) == nil {
                    _ = task(for: t.id)
                }
            }
            updateTaskState(t.id, state: t.status.state)
            notifyChange()
            return
        }

        if let e = try? decoder.decode(TaskStatusUpdateEvent.self, from: payload) {
            let task = task(for: e.taskId)
            if let msg = e.status.message {
                for part in msg.parts {
                    if let step = part.data {
                        upsertRound(step, in: task)
                    }
                }
            }
            updateTaskState(e.taskId, state: e.status.state)
            notifyChange()
            return
        }

        if let e = try? decoder.decode(TaskArtifactUpdateEvent.self, from: payload) {
            let task = task(for: e.taskId)
            let text = e.artifact.parts.compactMap(\.text).joined()
            task.summaryBuffer += text
            if e.lastChunk == true {
                task.summary = task.summaryBuffer
            }
            notifyChange()
        }
    }

    private func adoptServerTaskId(_ serverId: String) {
        guard !orchestratesSubTasks else { return }
        guard let mainId = activeMainTaskId,
              let task = tasks.first(where: { $0.id == mainId }) else { return }
        task.id = serverId
        if selectedTaskId == mainId { selectedTaskId = serverId }
        if activeMainTaskId == mainId { activeMainTaskId = serverId }
        streamingTaskId = serverId
    }

    private func registerSubTask(_ serverId: String) {
        guard let mainId = activeMainTaskId else { return }
        guard tasks.first(where: { $0.id == serverId }) == nil else { return }

        let index = subTasks.count + 1
        let sub = AITask(
            id: serverId,
            prompt: "子任务 \(index)",
            parentTaskId: mainId,
            subtaskIndex: index,
            state: .working
        )
        tasks.append(sub)
        streamingTaskId = serverId
        selectedSubTaskId = serverId
        notifyChange()
    }

    private func updateTaskState(_ taskId: String, state: String) {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        if state == "TASK_STATE_FAILED" || state == "failed" {
            task.state = .failed
        } else if TaskState.isTerminal(state) {
            task.state = .completed
        } else if task.state != .failed {
            task.state = .working
            if task.isSubTask, selectedSubTaskId != taskId {
                selectedSubTaskId = taskId
            }
        }
        refreshMainTaskState(for: task.parentTaskId ?? task.id)
    }

    private func refreshMainTaskState(for taskId: String) {
        guard let main = tasks.first(where: { $0.id == taskId && !$0.isSubTask }) else { return }
        let children = tasks.filter { $0.parentTaskId == taskId }
        guard !children.isEmpty else { return }

        if children.contains(where: { $0.state == .working }) {
            main.state = .working
        } else if children.allSatisfy({ $0.state == .completed }) {
            main.state = .completed
        } else if children.contains(where: { $0.state == .failed }) {
            main.state = .failed
        }
    }

    private static func streamPayloadData(from data: Data) -> Data {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = envelope["result"] as? [String: Any]
        else {
            return data
        }
        for key in ["statusUpdate", "artifactUpdate", "task"] {
            if let inner = result[key] {
                return (try? JSONSerialization.data(withJSONObject: inner)) ?? data
            }
        }
        return (try? JSONSerialization.data(withJSONObject: result)) ?? data
    }

    private func task(for taskId: String) -> AITask {
        if let existing = tasks.first(where: { $0.id == taskId }) {
            streamingTaskId = taskId
            return existing
        }

        if orchestratesSubTasks {
            registerSubTask(taskId)
            return tasks.first(where: { $0.id == taskId })!
        }

        let prompt = pendingPrompt ?? "新任务"
        let task = AITask(id: taskId, prompt: prompt, state: .working)
        tasks.append(task)
        streamingTaskId = taskId
        selectedTaskId = taskId
        activeMainTaskId = taskId
        return task
    }

    private func upsertRound(_ step: ReActStep, in task: AITask) {
        if step.step == "task_start" {
            if let text = step.text, !text.isEmpty {
                task.prompt = text
            }
            return
        }

        let idx = step.round - 1
        guard idx >= 0 else { return }
        while task.rounds.count <= idx { task.rounds.append(Round()) }
        switch step.step {
        case "reasoning":
            task.rounds[idx].reasoning = step.text
        case "tool_call":
            task.rounds[idx].toolCalls.append(ToolCall(
                name: step.name ?? "",
                args: step.args ?? [:]
            ))
        case "tool_result":
            task.rounds[idx].toolResults.append(ToolResult(
                name: step.name ?? "",
                result: step.result ?? "",
                ok: step.ok ?? true
            ))
        default:
            break
        }
    }

    static func isMultiTaskPrompt(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["multi task", "multi-task", "multitask", "多任务"].contains { lowered.contains($0) }
    }
}

enum ConnectionErrorMessage {
    static func message(for error: Error, serverURL: URL) -> String {
        let host = serverURL.host ?? serverURL.absoluteString
        var lines: [String] = []

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                lines.append("无法找到服务器「\(host)」。")
            case .cannotConnectToHost:
                lines.append("无法连接到「\(host)」。")
            case .notConnectedToInternet:
                lines.append("当前无网络连接。")
            case .timedOut:
                lines.append("连接超时。")
            case .badServerResponse:
                lines.append("服务器响应异常。")
            case .secureConnectionFailed:
                lines.append("无法建立安全连接。")
            default:
                lines.append("连接失败。")
            }
        } else {
            lines.append("连接失败。")
        }

        lines.append("请确认后端已启动，并在设置中检查 Server URL（当前：\(serverURL.absoluteString)）。")

        if let hint = localhostHint(for: serverURL) {
            lines.append(hint)
        }

        return lines.joined(separator: "\n")
    }

    private static func localhostHint(for url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" else { return nil }
#if os(iOS)
        return "在真机上运行时，localhost 指向手机本身，请改用 Mac 的局域网 IP。"
#else
        return nil
#endif
    }
}
