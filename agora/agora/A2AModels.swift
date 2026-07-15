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
    let text: String?
    let data: ReActStep?
    let mediaType: String?

    init(text: String? = nil, data: ReActStep? = nil, mediaType: String? = nil) {
        self.text = text
        self.data = data
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        data = try? container.decode(ReActStep.self, forKey: .data)
    }
}

struct Message: Codable {
    let parts: [Part]

    init(parts: [Part] = []) {
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parts = (try? container.decode([Part].self, forKey: .parts)) ?? []
    }
}

// MARK: - Events (A2A 1.0)

struct TaskStatus: Codable {
    let state: String
    let message: Message?

    init(state: String, message: Message? = nil) {
        self.state = state
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        message = try? container.decode(Message.self, forKey: .message)
    }
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
        switch label.lowercased() {
        case "working", "task_state_working", "task_state_submitted", "submitted":
            return .working
        case "completed", "task_state_completed":
            return .completed
        case "failed", "task_state_failed", "task_state_canceled", "task_state_rejected", "canceled", "rejected":
            return .failed
        default:
            return .idle
        }
    }

    static func isTerminal(_ state: String) -> Bool {
        switch state.lowercased() {
        case "completed", "failed", "canceled", "rejected",
             "task_state_completed", "task_state_failed",
             "task_state_canceled", "task_state_rejected":
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
    var skillId: String? = nil
    var skillName: String? = nil
    let createdAt: Date

    var summaryBuffer = ""

    var isSubTask: Bool { parentTaskId != nil }

    init(
        id: String,
        prompt: String,
        parentTaskId: String? = nil,
        subtaskIndex: Int? = nil,
        state: TaskState = .working,
        skillId: String? = nil,
        skillName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.parentTaskId = parentTaskId
        self.subtaskIndex = subtaskIndex
        self.state = state
        self.skillId = skillId
        self.skillName = skillName
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

struct AgentInterface: Codable, Equatable {
    let url: String
    var protocolBinding: String?
    var protocolVersion: String?
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
    var supportedInterfaces: [AgentInterface]?
    var provider: AgentProvider?
    var documentationUrl: String?
    var iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, description, url, version, protocolVersion
        case capabilities, defaultInputModes, defaultOutputModes, skills
        case supportedInterfaces, provider, documentationUrl, iconUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        capabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities)
        defaultInputModes = try container.decodeIfPresent([String].self, forKey: .defaultInputModes)
        defaultOutputModes = try container.decodeIfPresent([String].self, forKey: .defaultOutputModes)
        skills = try container.decodeIfPresent([AgentSkill].self, forKey: .skills)
        supportedInterfaces = try container.decodeIfPresent([AgentInterface].self, forKey: .supportedInterfaces)
        provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider)
        documentationUrl = try container.decodeIfPresent(String.self, forKey: .documentationUrl)
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)

        if let directURL = try container.decodeIfPresent(String.self, forKey: .url) {
            url = directURL
        } else if let iface = Self.preferredInterface(from: supportedInterfaces) {
            url = iface.url
            if protocolVersion == nil {
                protocolVersion = iface.protocolVersion
            }
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.url,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing url and supportedInterfaces")
            )
        }
    }

    init(
        name: String,
        description: String,
        url: String,
        version: String,
        protocolVersion: String? = nil,
        capabilities: AgentCapabilities? = nil,
        defaultInputModes: [String]? = nil,
        defaultOutputModes: [String]? = nil,
        skills: [AgentSkill]? = nil,
        supportedInterfaces: [AgentInterface]? = nil,
        provider: AgentProvider? = nil,
        documentationUrl: String? = nil,
        iconUrl: String? = nil
    ) {
        self.name = name
        self.description = description
        self.url = url
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.defaultInputModes = defaultInputModes
        self.defaultOutputModes = defaultOutputModes
        self.skills = skills
        self.supportedInterfaces = supportedInterfaces
        self.provider = provider
        self.documentationUrl = documentationUrl
        self.iconUrl = iconUrl
    }

    /// Replace localhost/127.0.0.1 in endpoint URLs with the host used to fetch this card.
    func rewritingLocalHost(with requestHost: String?) -> AgentCard {
        guard let requestHost, !requestHost.isEmpty else { return self }
        let rewrittenInterfaces = supportedInterfaces?.map { iface in
            AgentInterface(
                url: Self.rewriteLocalHost(in: iface.url, to: requestHost),
                protocolBinding: iface.protocolBinding,
                protocolVersion: iface.protocolVersion
            )
        }
        return AgentCard(
            name: name,
            description: description,
            url: Self.rewriteLocalHost(in: url, to: requestHost),
            version: version,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            defaultInputModes: defaultInputModes,
            defaultOutputModes: defaultOutputModes,
            skills: skills,
            supportedInterfaces: rewrittenInterfaces,
            provider: provider,
            documentationUrl: documentationUrl,
            iconUrl: iconUrl
        )
    }

    private static func preferredInterface(from interfaces: [AgentInterface]?) -> AgentInterface? {
        guard let interfaces, !interfaces.isEmpty else { return nil }
        return interfaces.first { $0.protocolBinding?.uppercased() == "JSONRPC" } ?? interfaces[0]
    }

    private static func rewriteLocalHost(in endpoint: String, to host: String) -> String {
        guard var components = URLComponents(string: endpoint),
              let endpointHost = components.host,
              isLocalHost(endpointHost) else {
            return endpoint
        }
        components.host = host
        return components.url?.absoluteString ?? endpoint
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "127.0.0.1"
    }
}
