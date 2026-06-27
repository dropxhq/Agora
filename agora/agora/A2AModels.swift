import Foundation
import Observation

// MARK: - Parts

struct TextPart: Codable {
    let text: String
}

struct DataPart: Codable {
    let data: ReActStep
    let mediaType: String?
}

struct ReActStep: Codable {
    let step: String        // "reasoning" | "tool_call" | "tool_result"
    let round: Int
    let text: String?
    let name: String?
    let args: [String: JSONValue]?
    let result: String?
    let ok: Bool?
}

// Heterogeneous JSON value
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
    var description: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(v)
        case .bool(let v):   return String(v)
        case .null:          return "null"
        }
    }
}

// MARK: - Message

struct Part: Codable {
    let text: String?       // TextPart
    let data: ReActStep?    // DataPart
    let mediaType: String?
}

struct Message: Codable {
    let parts: [Part]
}

// MARK: - Events (A2A v0.3)

struct TaskStatus: Codable {
    let state: String
    let message: Message?
}

struct TaskStatusUpdateEvent: Codable {
    let taskId: String
    let contextId: String?
    let status: TaskStatus
    let final: Bool?

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case contextId = "context_id"
        case status, final
    }
}

struct Artifact: Codable {
    let name: String?
    let parts: [Part]
}

struct TaskArtifactUpdateEvent: Codable {
    let taskId: String
    let contextId: String?
    let artifact: Artifact
    let append: Bool?
    let lastChunk: Bool?

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case contextId = "context_id"
        case artifact, append, lastChunk
    }
}

// MARK: - Client Models

struct ToolCall: Identifiable {
    let id = UUID()
    let name: String
    let args: [String: JSONValue]
    var argsPreview: String { args.map { "\($0.key): \($0.value.description)" }.joined(separator: ", ") }
}

struct ToolResult: Identifiable {
    let id = UUID()
    let name: String
    let result: String
    let ok: Bool
}

@Observable
class Round {
    var reasoning: String?
    var toolCalls: [ToolCall] = []
    var toolResults: [ToolResult] = []
}

enum TaskState { case idle, working, completed, failed

    static func from(label: String) -> TaskState {
        switch label {
        case "working": return .working
        case "completed": return .completed
        case "failed": return .failed
        default: return .idle
        }
    }
}
