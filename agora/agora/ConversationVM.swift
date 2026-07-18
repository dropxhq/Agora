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

    var thinking: [ThinkingItem] { displayTask?.thinking ?? [] }
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
            if task.hasResultContent || !task.thinking.isEmpty {
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
                    thinking: task.thinking.map(Self.persistThinkingItem),
                    rounds: nil,
                    summary: task.summary,
                    resultBlocks: task.resultBlocks,
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

        if let thinking = snapshot.thinking {
            let task = AITask(id: UUID().uuidString, prompt: "历史任务", state: .idle)
            task.thinking = thinking.compactMap(Self.thinkingItem(from:))
            applyLegacySummary(snapshot.summary, to: task)
            task.state = TaskState.from(label: snapshot.state ?? "idle")
            task.errorMessage = snapshot.errorMessage
            tasks = [task]
            activeMainTaskId = task.id
            selectedTaskId = task.id
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
        task.thinking = Self.flattenLegacyRounds(legacyRounds)
        applyLegacySummary(snapshot.summary, to: task)
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
        if let thinking = persisted.thinking, !thinking.isEmpty {
            task.thinking = thinking.compactMap(Self.thinkingItem(from:))
        } else if let rounds = persisted.rounds {
            task.thinking = Self.flattenLegacyRounds(rounds)
        }
        task.summary = persisted.summary
        task.resultBlocks = persisted.resultBlocks ?? []
        if task.resultBlocks.isEmpty, let summary = persisted.summary, !summary.isEmpty {
            task.resultBlocks = [.markdown(summary)]
        }
        if task.committedSummary.isEmpty {
            task.committedSummary = task.resultBlocks
                .compactMap {
                    if case .markdown(let text) = $0.payload { return text }
                    return nil
                }
                .joined(separator: "\n\n---\n\n")
        }
        task.summaryBuffer = ""
        task.errorMessage = persisted.errorMessage
        return task
    }

    private func applyLegacySummary(_ summary: String?, to task: AITask) {
        task.summary = summary
        if let summary, !summary.isEmpty {
            task.resultBlocks = [.markdown(summary)]
            task.committedSummary = summary
        }
        task.summaryBuffer = ""
    }

    private static func persistThinkingItem(_ item: ThinkingItem) -> PersistedThinkingItem {
        switch item {
        case .reasoning(_, let text):
            return PersistedThinkingItem(kind: "reasoning", text: text, toolCall: nil)
        case .toolCall(let call):
            let persistedResult = call.result.map {
                PersistedToolResult(id: $0.id, tool: $0.tool.rawValue, result: $0.result, ok: $0.ok)
            }
            return PersistedThinkingItem(
                kind: "tool_call",
                text: nil,
                toolCall: PersistedToolCall(
                    id: call.callId,
                    tool: call.tool.rawValue,
                    desc: call.desc,
                    args: call.args,
                    result: persistedResult
                )
            )
        }
    }

    private static func thinkingItem(from persisted: PersistedThinkingItem) -> ThinkingItem? {
        switch persisted.kind {
        case "reasoning":
            guard let text = persisted.text, !text.isEmpty else { return nil }
            return .reasoning(text)
        case "tool_call":
            guard let call = persisted.toolCall else { return nil }
            let result = call.result.map {
                ToolResult(id: $0.id, tool: ToolKind(wire: $0.tool), result: $0.result, ok: $0.ok)
            }
            return .toolCall(
                ToolCall(
                    callId: call.id,
                    tool: ToolKind(wire: call.tool),
                    desc: call.desc,
                    args: call.args,
                    result: result
                )
            )
        default:
            return nil
        }
    }

    /// Flatten legacy rounds; drop old `name` (no mapping to `tool`).
    private static func flattenLegacyRounds(_ rounds: [PersistedRound]) -> [ThinkingItem] {
        var items: [ThinkingItem] = []
        for round in rounds {
            if let reasoning = round.reasoning, !reasoning.isEmpty {
                items.append(.reasoning(reasoning))
            }
            let callCount = round.toolCalls.count
            let resultCount = round.toolResults.count
            let pairCount = max(callCount, resultCount)
            for i in 0..<pairCount {
                let legacyCall = i < callCount ? round.toolCalls[i] : nil
                let legacyResult = i < resultCount ? round.toolResults[i] : nil
                let result = legacyResult.map {
                    ToolResult(
                        id: nil,
                        tool: .unknown,
                        result: $0.result ?? "",
                        ok: $0.ok ?? true
                    )
                }
                items.append(
                    .toolCall(
                        ToolCall(
                            callId: nil,
                            tool: .unknown,
                            desc: nil,
                            args: legacyCall?.args ?? [:],
                            result: result
                        )
                    )
                )
            }
        }
        return items
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

        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           object["taskId"] as? String != nil || object["task_id"] as? String != nil,
           object["status"] as? [String: Any] != nil {
            // A2A 1.0 peels to `{ taskId, status, ... }` without a `kind` discriminator.
            applyStreamKindEvent(object, kind: "status-update")
            return
        }

        if let e = try? decoder.decode(TaskStatusUpdateEvent.self, from: payload) {
            let task = task(for: e.taskId)
            if let msg = e.status.message {
                applyStatusMessage(Self.messageObject(from: msg), to: task)
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
            applyArtifactParts(
                e.artifact.parts,
                to: task,
                artifactId: e.artifact.artifactId,
                artifactName: e.artifact.name,
                append: e.append,
                lastChunk: e.lastChunk
            )
                if e.lastChunk == true, orchestratesSubTasks, task.isSubTask {
                task.state = .completed
                if currentSubTaskId == task.id {
                    currentSubTaskId = nil
                }
            }
            notifyChange()
            return
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
            var isFinal = object["final"] as? Bool ?? false
            if let status = object["status"] as? [String: Any] {
                if let state = status["state"] as? String {
                    updateTaskState(taskId, state: state)
                    if TaskState.isTerminal(state) {
                        isFinal = true
                    }
                }
                if let message = status["message"] as? [String: Any] {
                    applyStatusMessage(message, to: task)
                }
            }
            if isFinal {
                promoteSummaryFromStreamBuffer(for: task)
            }
        case "artifact-update":
            let task = task(for: taskId)
            if let artifact = object["artifact"] as? [String: Any],
               let partDicts = artifact["parts"] as? [[String: Any]] {
                let parts = partDicts.map(Self.part(from:))
                let artifactId = artifact["artifactId"] as? String
                    ?? artifact["artifact_id"] as? String
                let artifactName = artifact["name"] as? String
                let append = object["append"] as? Bool
                let lastChunk = object["lastChunk"] as? Bool ?? object["last_chunk"] as? Bool
                applyArtifactParts(
                    parts,
                    to: task,
                    artifactId: artifactId,
                    artifactName: artifactName,
                    append: append,
                    lastChunk: lastChunk
                )
            }
        default:
            break
        }
        notifyChange()
    }

    private static func part(from dict: [String: Any]) -> Part {
        let dataValue: JSONValue?
        if let data = dict["data"] {
            dataValue = JSONValue.fromJSONObject(data)
        } else {
            dataValue = nil
        }
        return Part(
            text: dict["text"] as? String,
            data: dataValue,
            raw: dict["raw"] as? String,
            url: dict["url"] as? String,
            mediaType: dict["mediaType"] as? String ?? dict["media_type"] as? String,
            filename: dict["filename"] as? String ?? dict["fileName"] as? String
        )
    }

    private static func messageObject(from message: Message) -> [String: Any] {
        [
            "parts": message.parts.map { part -> [String: Any] in
                var dict: [String: Any] = [:]
                if let text = part.text { dict["text"] = text }
                if let data = part.data { dict["data"] = data.jsonObject }
                if let raw = part.raw { dict["raw"] = raw }
                if let url = part.url { dict["url"] = url }
                if let mediaType = part.mediaType { dict["mediaType"] = mediaType }
                if let filename = part.filename { dict["filename"] = filename }
                return dict
            }
        ]
    }

    /// Status message → thinking only (never result / summaryBuffer).
    private func applyStatusMessage(_ message: [String: Any], to task: AITask) {
        guard let parts = message["parts"] as? [[String: Any]] else { return }
        for partDict in parts {
            let part = Self.part(from: partDict)
            if let step = part.reactStep {
                applyProcessStep(step, to: task)
                continue
            }
            appendThinkingFallback(from: partDict, part: part, to: task)
        }
    }

    private func applyProcessStep(_ step: ReActStep, to task: AITask) {
        switch step.type {
        case "reasoning":
            let text = step.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                appendThinkingFallback(from: step, to: task)
            } else {
                if orchestratesSubTasks, task.isSubTask, task.thinking.isEmpty {
                    task.prompt = text
                }
                task.thinking.append(.reasoning(text))
            }
        case "tool_call":
            guard let toolWire = step.tool, !toolWire.isEmpty else {
                appendThinkingFallback(from: step, to: task)
                return
            }
            task.thinking.append(
                .toolCall(
                    ToolCall(
                        callId: step.id,
                        tool: ToolKind(wire: toolWire),
                        desc: step.desc,
                        args: step.args ?? [:]
                    )
                )
            )
        case "tool_result":
            guard let toolWire = step.tool, !toolWire.isEmpty else {
                appendThinkingFallback(from: step, to: task)
                return
            }
            attachToolResult(
                ToolResult(
                    id: step.id,
                    tool: ToolKind(wire: toolWire),
                    result: step.result ?? "",
                    ok: step.ok ?? true
                ),
                to: task
            )
        default:
            appendThinkingFallback(from: step, to: task)
        }
    }

    private func attachToolResult(_ result: ToolResult, to task: AITask) {
        if let callId = result.id, !callId.isEmpty {
            if let index = task.thinking.firstIndex(where: {
                if case .toolCall(let call) = $0 {
                    return call.callId == callId && call.result == nil
                }
                return false
            }), case .toolCall(var call) = task.thinking[index] {
                call.result = result
                task.thinking[index] = .toolCall(call)
                return
            }
        } else if let index = task.thinking.firstIndex(where: {
            if case .toolCall(let call) = $0 {
                return (call.callId == nil || call.callId?.isEmpty == true) && call.result == nil
            }
            return false
        }), case .toolCall(var call) = task.thinking[index] {
            call.result = result
            task.thinking[index] = .toolCall(call)
            return
        }

        // No matching call — keep content as a placeholder tool row.
        task.thinking.append(
            .toolCall(
                ToolCall(
                    callId: result.id,
                    tool: result.tool,
                    desc: nil,
                    args: [:],
                    result: result
                )
            )
        )
    }

    private func appendThinkingFallback(from partDict: [String: Any], part: Part, to task: AITask) {
        if let text = part.text, !text.isEmpty {
            task.thinking.append(.reasoning(text))
            return
        }
        if let data = partDict["data"] as? [String: Any] {
            if let content = data["content"] as? String, !content.isEmpty {
                task.thinking.append(.reasoning(content))
                return
            }
            if let text = data["text"] as? String, !text.isEmpty {
                task.thinking.append(.reasoning(text))
                return
            }
            if let title = data["title"] as? String {
                let desc = data["desc"] as? String ?? ""
                let body = [title, desc].filter { !$0.isEmpty }.joined(separator: "\n")
                if !body.isEmpty {
                    task.thinking.append(.reasoning(body))
                    return
                }
            }
            if let dataValue = part.data {
                task.thinking.append(.reasoning("```json\n\(dataValue.prettyPrinted)\n```"))
                return
            }
        }
        if let dataValue = part.data {
            task.thinking.append(.reasoning("```json\n\(dataValue.prettyPrinted)\n```"))
        }
    }

    private func appendThinkingFallback(from step: ReActStep, to task: AITask) {
        if let text = step.text, !text.isEmpty {
            task.thinking.append(.reasoning(text))
            return
        }
        if let result = step.result, !result.isEmpty {
            task.thinking.append(.reasoning(result))
            return
        }
        var object: [String: Any] = ["type": step.type]
        if let id = step.id { object["id"] = id }
        if let tool = step.tool { object["tool"] = tool }
        if let desc = step.desc { object["desc"] = desc }
        if let args = step.args {
            object["args"] = args.mapValues(\.jsonObject)
        }
        if let ok = step.ok { object["ok"] = ok }
        let value = JSONValue.fromJSONObject(object)
        task.thinking.append(.reasoning("```json\n\(value.prettyPrinted)\n```"))
    }

    /// Applies A2A artifact parts (text / data / raw / url) into structured result blocks.
    /// Text may stream via `append`; other kinds are committed as discrete blocks in order.
    private func applyArtifactParts(
        _ parts: [Part],
        to task: AITask,
        artifactId: String?,
        artifactName: String?,
        append: Bool?,
        lastChunk: Bool?
    ) {
        guard parts.contains(where: \.hasResultContent) else {
            if lastChunk == true {
                commitActiveArtifact(on: task)
            }
            return
        }

        let id = artifactId ?? "default"
        prepareArtifactStream(on: task, artifactId: id, artifactName: artifactName, append: append)

        for part in parts {
            if let text = part.text, !text.isEmpty {
                applyArtifactText(text, to: task, append: append)
            }
            if let data = part.data {
                flushTextBuffer(on: task)
                task.resultBlocks.append(
                    .json(
                        data.prettyPrinted,
                        artifactId: id,
                        artifactName: artifactName ?? task.activeArtifactName
                    )
                )
            }
            if let raw = part.raw, !raw.isEmpty {
                flushTextBuffer(on: task)
                task.resultBlocks.append(
                    .file(
                        Self.filePayload(base64: raw, mediaType: part.mediaType, filename: part.filename),
                        artifactId: id,
                        artifactName: artifactName ?? task.activeArtifactName
                    )
                )
            }
            if let url = part.url, !url.isEmpty {
                flushTextBuffer(on: task)
                task.resultBlocks.append(
                    .link(
                        .init(url: url, filename: part.filename, mediaType: part.mediaType),
                        artifactId: id,
                        artifactName: artifactName ?? task.activeArtifactName
                    )
                )
            }
        }

        refreshSummary(for: task)

        if lastChunk == true {
            commitActiveArtifact(on: task)
        }
    }

    private func prepareArtifactStream(
        on task: AITask,
        artifactId: String,
        artifactName: String?,
        append: Bool?
    ) {
        if append == true {
            if task.activeArtifactId == nil {
                task.activeArtifactId = artifactId
                task.activeArtifactName = artifactName
            }
            return
        }
        if task.activeArtifactId == artifactId {
            // Restart the current artifact's text buffer; keep prior committed blocks.
            task.summaryBuffer = ""
            task.activeArtifactName = artifactName ?? task.activeArtifactName
            return
        }
        commitActiveArtifact(on: task)
        task.activeArtifactId = artifactId
        task.activeArtifactName = artifactName
    }

    /// Merges text chunks for the active artifact stream.
    private func applyArtifactText(
        _ text: String,
        to task: AITask,
        append: Bool?
    ) {
        if append == true || !task.summaryBuffer.isEmpty {
            task.summaryBuffer += text
        } else {
            task.summaryBuffer = text
        }
    }

    private func flushTextBuffer(on task: AITask) {
        let chunk = task.summaryBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        task.resultBlocks.append(
            .markdown(
                chunk,
                artifactId: task.activeArtifactId,
                artifactName: task.activeArtifactName
            )
        )
        if task.committedSummary.isEmpty {
            task.committedSummary = chunk
        } else if !task.committedSummary.contains(chunk) {
            task.committedSummary += "\n\n---\n\n" + chunk
        }
        task.summaryBuffer = ""
    }

    private func commitActiveArtifact(on task: AITask) {
        flushTextBuffer(on: task)
        task.activeArtifactId = nil
        task.activeArtifactName = nil
        refreshSummary(for: task)
    }

    private func refreshSummary(for task: AITask) {
        let live = task.summaryBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces = task.resultBlocks.map(\.summaryText)
        if !live.isEmpty {
            pieces.append(live)
        }
        let combined = pieces.joined(separator: "\n\n---\n\n")
        task.summary = combined.isEmpty ? nil : combined
    }

    private func combinedSummary(for task: AITask) -> String {
        let live = task.summaryBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces = task.resultBlocks.map(\.summaryText)
        if !live.isEmpty { pieces.append(live) }
        return pieces.joined(separator: "\n\n---\n\n")
    }

    private func promoteSummaryFromStreamBuffer(for task: AITask) {
        commitActiveArtifact(on: task)
        guard task.summary == nil || task.summary?.isEmpty == true else { return }
        let summary = combinedSummary(for: task)
        guard !summary.isEmpty else { return }
        task.summary = summary
    }

    private static func filePayload(
        base64: String,
        mediaType: String?,
        filename: String?
    ) -> ResultBlock.FilePayload {
        let data = Data(base64Encoded: base64)
        let byteCount = data?.count ?? (base64.count * 3 / 4)
        var preview: String?
        let mime = (mediaType ?? "").lowercased()
        let textLike = mime.hasPrefix("text/")
            || mime == "application/json"
            || mime == "application/csv"
            || mime.hasSuffix("+json")
            || (filename?.lowercased().hasSuffix(".csv") == true)
        if textLike, let data, let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 4_000 {
                preview = String(trimmed.prefix(4_000)) + "\n…"
            } else {
                preview = trimmed
            }
        }
        return .init(
            filename: filename,
            mediaType: mediaType,
            previewText: preview,
            base64: base64,
            byteCount: byteCount
        )
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
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(detail.isEmpty ? "连接失败。" : "连接失败：\(detail)")
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
