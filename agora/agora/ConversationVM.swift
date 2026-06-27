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

    func send(text: String, client: A2AClient) {
        rounds = []
        summary = nil
        summaryBuffer = ""
        state = .working
        errorMessage = nil

        Task { @MainActor in
            do {
                let stream = client.sendStreamingMessage(text: text)
                for try await data in stream {
                    apply(data)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.state = .failed
            }
        }
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
            return
        }

        // Try ArtifactUpdateEvent
        if let e = try? decoder.decode(TaskArtifactUpdateEvent.self, from: data) {
            let text = e.artifact.parts.compactMap(\.text).joined()
            summaryBuffer += text
            if e.lastChunk == true {
                summary = summaryBuffer
            }
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
