import Foundation
import Observation

@Observable
class ConversationVM {
    var tasks: [AITask] = []
    var selectedTaskId: String?

    private var pendingPrompt: String?
    private var streamingTaskId: String?
    private let decoder = JSONDecoder()

    var onChange: (() -> Void)?

    var selectedTask: AITask? {
        if let id = selectedTaskId {
            return tasks.first { $0.id == id }
        }
        return tasks.last
    }

    var rounds: [Round] { selectedTask?.rounds ?? [] }
    var summary: String? { selectedTask?.summary }
    var state: TaskState { selectedTask?.state ?? .idle }
    var errorMessage: String? { selectedTask?.errorMessage }

    var isStreaming: Bool {
        tasks.contains { $0.state == .working }
    }

    func selectTask(_ id: String) {
        selectedTaskId = id
        notifyChange()
    }

    func send(text: String, client: A2AClient, contextId: String) {
        pendingPrompt = text
        streamingTaskId = nil

        Task { @MainActor in
            do {
                let stream = client.sendStreamingMessage(text: text, contextId: contextId)
                for try await data in stream {
                    apply(data)
                }
                pendingPrompt = nil
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
            selectedTaskId: selectedTaskId
        )
    }

    func restore(from snapshot: SessionSnapshot) {
        if let persistedTasks = snapshot.tasks, !persistedTasks.isEmpty {
            tasks = persistedTasks.map { restoreTask(from: $0) }
            selectedTaskId = snapshot.selectedTaskId ?? tasks.last?.id
            return
        }

        // Migrate legacy single-task snapshot
        guard let legacyRounds = snapshot.rounds else {
            tasks = []
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
        selectedTaskId = task.id
    }

    private func restoreTask(from persisted: PersistedTask) -> AITask {
        let task = AITask(
            id: persisted.id,
            prompt: persisted.prompt,
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
        } else if let prompt = pendingPrompt {
            let task = AITask(id: UUID().uuidString, prompt: prompt, state: .failed)
            task.errorMessage = message
            tasks.append(task)
            selectedTaskId = task.id
        }
        pendingPrompt = nil
        streamingTaskId = nil
        notifyChange()
    }

    @MainActor
    private func apply(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        if let e = try? decoder.decode(TaskStatusUpdateEvent.self, from: data) {
            let task = task(for: e.taskId)
            if let msg = e.status.message {
                for part in msg.parts {
                    if let step = part.data {
                        upsertRound(step, in: task)
                    }
                }
            }
            if e.status.state == "failed" {
                task.state = .failed
            } else if e.final == true {
                task.state = .completed
            } else if task.state != .failed {
                task.state = .working
            }
            notifyChange()
            return
        }

        if let e = try? decoder.decode(TaskArtifactUpdateEvent.self, from: data) {
            let task = task(for: e.taskId)
            let text = e.artifact.parts.compactMap(\.text).joined()
            task.summaryBuffer += text
            if e.lastChunk == true {
                task.summary = task.summaryBuffer
            }
            notifyChange()
        }
    }

    private func task(for taskId: String) -> AITask {
        if let existing = tasks.first(where: { $0.id == taskId }) {
            streamingTaskId = taskId
            return existing
        }

        let prompt = pendingPrompt ?? "新任务"
        pendingPrompt = nil
        let task = AITask(id: taskId, prompt: prompt, state: .working)
        tasks.append(task)
        streamingTaskId = taskId
        selectedTaskId = taskId
        return task
    }

    private func upsertRound(_ step: ReActStep, in task: AITask) {
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
