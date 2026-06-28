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

// MARK: - Events (A2A 1.0)

struct TaskStatus: Codable {
    let state: String
    let message: Message?
}

struct A2ATask: Codable {
    let id: String
    let contextId: String?
    let status: TaskStatus
}

struct TaskStatusUpdateEvent: Codable {
    let taskId: String
    let contextId: String?
    let status: TaskStatus
}

struct Artifact: Codable {
    let artifactId: String?
    let name: String?
    let parts: [Part]
}

struct TaskArtifactUpdateEvent: Codable {
    let taskId: String
    let contextId: String?
    let artifact: Artifact
    let append: Bool?
    let lastChunk: Bool?
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
        case "working", "TASK_STATE_WORKING", "TASK_STATE_SUBMITTED":
            return .working
        case "completed", "TASK_STATE_COMPLETED":
            return .completed
        case "failed", "TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED":
            return .failed
        default:
            return .idle
        }
    }

    static func isTerminal(_ state: String) -> Bool {
        switch state {
        case "completed", "failed",
             "TASK_STATE_COMPLETED", "TASK_STATE_FAILED",
             "TASK_STATE_CANCELED", "TASK_STATE_REJECTED":
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}

@Observable
class AITask: Identifiable {
    var id: String
    var prompt: String
    var parentTaskId: String?
    var subtaskIndex: Int?
    var rounds: [Round] = []
    var summary: String? = nil
    var state: TaskState = .working
    var errorMessage: String? = nil
    let createdAt: Date

    var summaryBuffer = ""

    var isSubTask: Bool { parentTaskId != nil }

    init(
        id: String,
        prompt: String,
        parentTaskId: String? = nil,
        subtaskIndex: Int? = nil,
        state: TaskState = .working,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.parentTaskId = parentTaskId
        self.subtaskIndex = subtaskIndex
        self.state = state
        self.createdAt = createdAt
    }

    var promptPreview: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(28)) + "…"
    }

    var taskIdSuffix: String {
        String(id.suffix(8))
    }
}

// MARK: - Agent Card (A2A discovery)

struct AgentProvider: Codable, Equatable {
    var organization: String?
    var url: String?
}

struct AgentCapabilities: Codable, Equatable {
    var streaming: Bool?
    var pushNotifications: Bool?
}

struct AgentSkill: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    var tags: [String]?
    var examples: [String]?
}

struct AgentCard: Codable, Equatable {
    let name: String
    let description: String
    let url: String
    let version: String
    var protocolVersion: String?
    var capabilities: AgentCapabilities?
    var defaultInputModes: [String]?
    var defaultOutputModes: [String]?
    var skills: [AgentSkill]?
    var provider: AgentProvider?
    var documentationUrl: String?
    var iconUrl: String?
}
