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
    private var streamTask: Task<Void, Never>?
    private var orchestratesSubTasks = false
    private var multiTaskServerId: String?
    private var currentSubTaskId: String?
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
        return subTasks(for: main.id)
    }

    func subTasks(for mainId: String) -> [AITask] {
        tasks
            .filter { $0.parentTaskId == mainId }
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

    func send(text: String, client: A2AClient, contextId: String, skill: AgentSkill? = nil) {
        streamTask?.cancel()

        let placeholderId = "main-\(UUID().uuidString)"
        let task = AITask(
            id: placeholderId,
            prompt: text,
            state: .working,
            skillId: skill?.id,
            skillName: skill?.name
        )
        tasks.append(task)
        activeMainTaskId = placeholderId
        selectedSubTaskId = nil
        selectedTaskId = placeholderId
        streamingTaskId = placeholderId
        orchestratesSubTasks = Self.isMultiTaskPrompt(text)
        multiTaskServerId = nil
        currentSubTaskId = nil
        pendingPrompt = text
        notifyChange()

        streamTask = Task { @MainActor in
            do {
                let stream = client.sendStreamingMessage(text: text, contextId: contextId)
                for try await data in stream {
                    apply(data)
                }
                finalizeStreamingTaskIfNeeded()
                pendingPrompt = nil
                orchestratesSubTasks = false
                multiTaskServerId = nil
                currentSubTaskId = nil
            } catch is CancellationError {
                markStreamingStopped()
            } catch {
                handleStreamError(error, serverURL: client.baseURL)
            }
            streamTask = nil
        }
    }

    func stop() {
        guard isStreaming else { return }
        streamTask?.cancel()
        streamTask = nil
        markStreamingStopped()
    }

    @MainActor
    private func markStreamingStopped() {
        for task in tasks where task.state == .working {
            promoteSummaryFromStreamBuffer(for: task)
            if task.summary != nil || !task.rounds.isEmpty {
                task.state = .completed
            } else {
                task.state = .idle
            }
            refreshMainTaskState(for: task.parentTaskId ?? task.id)
        }
        pendingPrompt = nil
        streamingTaskId = nil
        orchestratesSubTasks = false
        multiTaskServerId = nil
        currentSubTaskId = nil
        notifyChange()
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            tasks: tasks.map { task in
                PersistedTask(
                    id: task.id,
                    prompt: task.prompt,
                    parentTaskId: task.parentTaskId,
                    subtaskIndex: task.subtaskIndex,
                    skillId: task.skillId,
                    skillName: task.skillName,
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
            skillId: persisted.skillId,
            skillName: persisted.skillName,
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
        let message: String
        if let serverError = error as? ServerResponseError {
            message = serverError.message
        } else {
            message = ConnectionErrorMessage.message(for: error, serverURL: serverURL)
        }
        markStreamingTaskFailed(message: message)
    }

    @MainActor
    private func markStreamingTaskFailed(message: String) {
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
        multiTaskServerId = nil
        currentSubTaskId = nil
        notifyChange()
    }

    @MainActor
    private func finalizeStreamingTaskIfNeeded() {
        guard let taskId = streamingTaskId ?? activeMainTaskId,
              let task = tasks.first(where: { $0.id == taskId }),
              task.state == .working else {
            return
        }
        promoteSummaryFromStreamBuffer(for: task)
        if task.summary != nil {
            task.state = .completed
        } else {
            task.state = .failed
            task.errorMessage = task.errorMessage ?? "服务器未返回有效响应。"
        }
        refreshMainTaskState(for: task.parentTaskId ?? task.id)
        streamingTaskId = nil
        notifyChange()
    }

    @MainActor
    private func apply(_ json: String) {
        if let serverError = ServerErrorMessage.parse(from: json) {
            markStreamingTaskFailed(message: serverError)
            return
        }

        guard let data = json.data(using: .utf8) else { return }
        let payload = Self.streamPayloadData(from: data)

        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let kind = object["kind"] as? String {
            applyStreamKindEvent(object, kind: kind)
            return
        }

        if let t = try? decoder.decode(A2ATask.self, from: payload) {
            if orchestratesSubTasks {
                multiTaskServerId = t.id
                _ = ensureCurrentSubTask()
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
            if e.status.state.lowercased() == "task_state_failed" || e.status.state.lowercased() == "failed" {
                task.errorMessage = ServerErrorMessage.parse(from: payload) ?? task.errorMessage
            }
            notifyChange()
            return
        }

        if let e = try? decoder.decode(TaskArtifactUpdateEvent.self, from: payload) {
            let task = task(for: e.taskId)
            let text = e.artifact.parts.compactMap(\.text).joined()
            task.summaryBuffer += text
            if e.lastChunk == true {
                task.summary = task.summaryBuffer
                if orchestratesSubTasks, task.isSubTask {
                    task.state = .completed
                }
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

    private func ensureCurrentSubTask(prompt: String? = nil) -> AITask {
        if let currentId = currentSubTaskId,
           let task = tasks.first(where: { $0.id == currentId }) {
            streamingTaskId = currentId
            return task
        }
        return beginNextSubTask(prompt: prompt ?? "子任务 \(subTasks.count + 1)")
    }

    private func beginNextSubTask(prompt: String) -> AITask {
        guard let mainId = activeMainTaskId else {
            let fallback = AITask(id: UUID().uuidString, prompt: prompt, state: .working)
            tasks.append(fallback)
            return fallback
        }

        let index = subTasks.count + 1
        let subId = "\(mainId)-sub-\(index)"
        let sub = AITask(
            id: subId,
            prompt: prompt,
            parentTaskId: mainId,
            subtaskIndex: index,
            state: .working
        )
        tasks.append(sub)
        currentSubTaskId = subId
        streamingTaskId = subId
        selectedSubTaskId = subId
        notifyChange()
        return sub
    }

    private func updateTaskState(_ taskId: String, state: String) {
        if orchestratesSubTasks, taskId == multiTaskServerId {
            if state.lowercased() == "failed" || state.lowercased() == "task_state_failed" {
                for sub in subTasks { sub.state = .failed }
                if let mainId = activeMainTaskId,
                   let main = tasks.first(where: { $0.id == mainId }) {
                    main.state = .failed
                }
            } else if TaskState.isTerminal(state) {
                for sub in subTasks where sub.state == .working {
                    sub.state = .completed
                }
                if let mainId = activeMainTaskId,
                   let main = tasks.first(where: { $0.id == mainId }) {
                    main.state = .completed
                }
            } else if let mainId = activeMainTaskId,
                      let main = tasks.first(where: { $0.id == mainId }),
                      main.state != .failed {
                main.state = .working
            }
            return
        }

        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        if state.lowercased() == "task_state_failed" || state.lowercased() == "failed" {
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

    @MainActor
    private func applyStreamKindEvent(_ object: [String: Any], kind: String) {
        let taskId = (object["taskId"] as? String) ?? (object["id"] as? String)
        guard let taskId else { return }

        switch kind {
        case "task":
            adoptServerTaskId(taskId)
            if tasks.first(where: { $0.id == taskId }) == nil {
                _ = task(for: taskId)
            }
            if let status = object["status"] as? [String: Any],
               let state = status["state"] as? String {
                updateTaskState(taskId, state: state)
            }
        case "status-update":
            let task = task(for: taskId)
            let isFinal = object["final"] as? Bool ?? false
            if let status = object["status"] as? [String: Any] {
                if let message = status["message"] as? [String: Any] {
                    applyAgentStreamMessage(message, to: task, isFinal: isFinal)
                }
                if let state = status["state"] as? String {
                    updateTaskState(taskId, state: state)
                }
            }
            if isFinal {
                promoteSummaryFromStreamBuffer(for: task)
            }
        case "artifact-update":
            let task = task(for: taskId)
            if let artifact = object["artifact"] as? [String: Any],
               let parts = artifact["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    task.summaryBuffer += text
                    task.summary = task.summaryBuffer
                }
            }
        default:
            break
        }
        notifyChange()
    }

    private func applyAgentStreamMessage(_ message: [String: Any], to task: AITask, isFinal: Bool) {
        guard let parts = message["parts"] as? [[String: Any]] else { return }

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                if isFinal {
                    task.summaryBuffer = text
                    task.summary = text
                } else {
                    appendStreamText(to: task, content: text)
                    task.summaryBuffer = text
                }
                continue
            }

            guard let data = part["data"] as? [String: Any],
                  let messageType = data["message_type"] as? String else {
                continue
            }

            switch messageType {
            case "initial":
                let title = data["title"] as? String ?? ""
                let desc = data["desc"] as? String ?? ""
                appendProcessNote(to: task, title: title, body: desc)
            case "execute":
                let name = data["execute_type"] as? String ?? "execute"
                let content = data["content"] as? String ?? ""
                appendExecuteStep(to: task, name: name, content: content)
            case "text":
                let content = data["content"] as? String ?? ""
                guard !content.isEmpty else { continue }
                if isFinal {
                    task.summaryBuffer = content
                    task.summary = content
                } else {
                    appendStreamText(to: task, content: content)
                    task.summaryBuffer = content
                }
            case "error":
                let content = data["content"] as? String ?? data["data"] as? String ?? "未知错误"
                task.errorMessage = content
                task.state = .failed
            case "completed":
                break
            default:
                break
            }
        }
    }

    private func appendStreamText(to task: AITask, content: String) {
        let round = Round()
        round.reasoning = content
        task.rounds.append(round)
    }

    private func promoteSummaryFromStreamBuffer(for task: AITask) {
        guard task.summary == nil, !task.summaryBuffer.isEmpty else { return }
        let summary = task.summaryBuffer
        task.summary = summary
        if let last = task.rounds.last,
           last.toolCalls.isEmpty,
           last.toolResults.isEmpty,
           last.reasoning == summary {
            task.rounds.removeLast()
        }
    }

    private func appendProcessNote(to task: AITask, title: String, body: String) {
        let round = Round()
        round.reasoning = [title, body]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        task.rounds.append(round)
    }

    private func appendExecuteStep(to task: AITask, name: String, content: String) {
        let round = Round()
        if !content.isEmpty {
            round.reasoning = content
        }
        round.toolCalls.append(ToolCall(name: name, args: [:]))
        task.rounds.append(round)
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
        for key in ["statusUpdate", "status-update", "artifactUpdate", "artifact-update", "task"] {
            if let inner = result[key] {
                return (try? JSONSerialization.data(withJSONObject: inner)) ?? data
            }
        }
        if result["kind"] != nil {
            return (try? JSONSerialization.data(withJSONObject: result)) ?? data
        }
        return (try? JSONSerialization.data(withJSONObject: result)) ?? data
    }

    private func task(for taskId: String) -> AITask {
        if orchestratesSubTasks {
            if multiTaskServerId == nil {
                multiTaskServerId = taskId
            }
            return ensureCurrentSubTask()
        }

        if let existing = tasks.first(where: { $0.id == taskId }) {
            streamingTaskId = taskId
            return existing
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
            guard let text = step.text, !text.isEmpty else { return }
            if orchestratesSubTasks {
                if task.rounds.isEmpty && task.summary == nil {
                    task.prompt = text
                } else {
                    _ = beginNextSubTask(prompt: text)
                }
            } else {
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
