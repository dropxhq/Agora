import Foundation
import Observation

@Observable
class ConversationVM {
    var rounds: [Round] = []
    var summary: String? = nil
    var state: TaskState = .idle
    var errorMessage: String? = nil

    private var summaryBuffer = ""
    private let decoder = JSONDecoder()

    var onChange: (() -> Void)?

    func send(text: String, client: A2AClient, contextId: String) {
        rounds = []
        summary = nil
        summaryBuffer = ""
        state = .working
        errorMessage = nil

        Task { @MainActor in
            do {
                let stream = client.sendStreamingMessage(text: text, contextId: contextId)
                for try await data in stream {
                    apply(data)
                }
            } catch {
                self.errorMessage = ConnectionErrorMessage.message(for: error, serverURL: client.baseURL)
                self.state = .failed
                notifyChange()
            }
        }
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            rounds: rounds.map { round in
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
            summary: summary,
            state: stateLabel,
            errorMessage: errorMessage
        )
    }

    func restore(from snapshot: SessionSnapshot) {
        rounds = snapshot.rounds.map { persisted in
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
        summary = snapshot.summary
        summaryBuffer = snapshot.summary ?? ""
        state = TaskState.from(label: snapshot.state)
        errorMessage = snapshot.errorMessage
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "idle"
        case .working: return "working"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }

    private func notifyChange() {
        onChange?()
    }

    @MainActor
    private func apply(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        // Try StatusUpdateEvent
        if let e = try? decoder.decode(TaskStatusUpdateEvent.self, from: data) {
            if let msg = e.status.message {
                for part in msg.parts {
                    if let step = part.data {
                        upsertRound(step)
                    }
                }
            }
            if e.final == true {
                state = e.status.state == "failed" ? .failed : .completed
            }
            notifyChange()
            return
        }

        // Try ArtifactUpdateEvent
        if let e = try? decoder.decode(TaskArtifactUpdateEvent.self, from: data) {
            let text = e.artifact.parts.compactMap(\.text).joined()
            summaryBuffer += text
            if e.lastChunk == true {
                summary = summaryBuffer
            }
            notifyChange()
        }
    }

    private func upsertRound(_ step: ReActStep) {
        let idx = step.round - 1
        guard idx >= 0 else { return }
        while rounds.count <= idx { rounds.append(Round()) }
        switch step.step {
        case "reasoning":
            rounds[idx].reasoning = step.text
        case "tool_call":
            rounds[idx].toolCalls.append(ToolCall(
                name: step.name ?? "",
                args: step.args ?? [:]
            ))
        case "tool_result":
            rounds[idx].toolResults.append(ToolResult(
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
