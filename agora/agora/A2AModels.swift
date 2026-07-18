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
    let type: String        // "reasoning" | "tool_call" | "tool_result"
    let text: String?
    let id: String?
    let tool: String?
    let desc: String?
    let args: [String: JSONValue]?
    let result: String?
    let ok: Bool?
}

// Heterogeneous JSON value (A2A data parts + tool args)
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }

    var description: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(v)
        case .bool(let v): return String(v)
        case .null: return "null"
        case .object(let v):
            return "{" + v.map { "\($0.key): \($0.value.description)" }.joined(separator: ", ") + "}"
        case .array(let v):
            return "[" + v.map(\.description).joined(separator: ", ") + "]"
        }
    }

    /// Pretty JSON for artifact data rendering.
    var prettyPrinted: String {
        let object = jsonObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8)
        else {
            return description
        }
        return text
    }

    var jsonObject: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .object(let v): return v.mapValues(\.jsonObject)
        case .array(let v): return v.map(\.jsonObject)
        }
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func fromJSONObject(_ value: Any) -> JSONValue {
        switch value {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as NSNumber:
            // Bool is bridged as NSNumber; detect it first.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                return .bool(v.boolValue)
            }
            return .number(v.doubleValue)
        case let v as [String: Any]:
            return .object(v.mapValues { fromJSONObject($0) })
        case let v as [Any]:
            return .array(v.map { fromJSONObject($0) })
        case is NSNull:
            return .null
        default:
            return .null
        }
    }
}

// MARK: - Message

/// A2A 1.0 Part: content is one of text / data / raw / url.
struct Part: Codable {
    let text: String?
    let data: JSONValue?
    let raw: String?
    let url: String?
    let mediaType: String?
    let filename: String?

    init(
        text: String? = nil,
        data: JSONValue? = nil,
        raw: String? = nil,
        url: String? = nil,
        mediaType: String? = nil,
        filename: String? = nil
    ) {
        self.text = text
        self.data = data
        self.raw = raw
        self.url = url
        self.mediaType = mediaType
        self.filename = filename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
        raw = try container.decodeIfPresent(String.self, forKey: .raw)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
    }

    /// Status DataPart carrying a process event (`type` = reasoning / tool_call / tool_result).
    var reactStep: ReActStep? {
        data?.decode(ReActStep.self)
    }

    var hasResultContent: Bool {
        if let text, !text.isEmpty { return true }
        if data != nil { return true }
        if let raw, !raw.isEmpty { return true }
        if let url, !url.isEmpty { return true }
        return false
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

enum ToolKind: String, Codable, Equatable {
    case shell
    case webSearch = "web_search"
    case read
    case write
    case loadSkill = "load_skill"
    case unknown = "unknown"

    init(wire: String?) {
        guard let wire, let known = ToolKind(rawValue: wire) else {
            self = .unknown
            return
        }
        self = known
    }

    var displayName: String {
        switch self {
        case .shell: return "shell"
        case .webSearch: return "web_search"
        case .read: return "read"
        case .write: return "write"
        case .loadSkill: return "load_skill"
        case .unknown: return "tool"
        }
    }

    var systemImage: String {
        switch self {
        case .shell: return "terminal"
        case .webSearch: return "globe"
        case .read: return "doc.text"
        case .write: return "square.and.pencil"
        case .loadSkill: return "puzzlepiece.extension"
        case .unknown: return "wrench"
        }
    }
}

struct ToolResult: Equatable {
    var id: String?
    var tool: ToolKind
    var result: String
    var ok: Bool
}

struct ToolCall: Equatable {
    let itemId: UUID
    /// Wire `id` used to pair with `tool_result`; nil → sequential pairing.
    var callId: String?
    var tool: ToolKind
    var desc: String?
    var args: [String: JSONValue]
    var result: ToolResult?

    init(
        itemId: UUID = UUID(),
        callId: String? = nil,
        tool: ToolKind,
        desc: String? = nil,
        args: [String: JSONValue] = [:],
        result: ToolResult? = nil
    ) {
        self.itemId = itemId
        self.callId = callId
        self.tool = tool
        self.desc = desc
        self.args = args
        self.result = result
    }

    var argsPreview: String {
        args.map { "\($0.key): \($0.value.description)" }.joined(separator: ", ")
    }
}

enum ThinkingItem: Identifiable, Equatable {
    case reasoning(id: UUID, text: String)
    case toolCall(ToolCall)

    var id: UUID {
        switch self {
        case .reasoning(let id, _): return id
        case .toolCall(let call): return call.itemId
        }
    }

    static func reasoning(_ text: String) -> ThinkingItem {
        .reasoning(id: UUID(), text: text)
    }
}

/// Renderable artifact content (A2A text / data / raw / url).
struct ResultBlock: Identifiable, Codable, Equatable {
    let id: UUID
    var artifactId: String?
    var artifactName: String?
    var payload: Payload

    enum Payload: Codable, Equatable {
        case markdown(String)
        case json(String)
        case file(FilePayload)
        case link(LinkPayload)
    }

    struct FilePayload: Codable, Equatable {
        var filename: String?
        var mediaType: String?
        var previewText: String?
        var base64: String?
        var byteCount: Int

        var isImage: Bool {
            (mediaType ?? "").lowercased().hasPrefix("image/")
        }

        var isTextLike: Bool {
            let mime = (mediaType ?? "").lowercased()
            return mime.hasPrefix("text/")
                || mime == "application/json"
                || mime == "application/csv"
                || mime.hasSuffix("+json")
        }

        var imageData: Data? {
            guard isImage, let base64, !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    struct LinkPayload: Codable, Equatable {
        var url: String
        var filename: String?
        var mediaType: String?

        var isImage: Bool {
            (mediaType ?? "").lowercased().hasPrefix("image/")
        }
    }

    static func markdown(
        _ text: String,
        artifactId: String? = nil,
        artifactName: String? = nil,
        id: UUID = UUID()
    ) -> ResultBlock {
        ResultBlock(id: id, artifactId: artifactId, artifactName: artifactName, payload: .markdown(text))
    }

    static func json(
        _ text: String,
        artifactId: String? = nil,
        artifactName: String? = nil
    ) -> ResultBlock {
        ResultBlock(id: UUID(), artifactId: artifactId, artifactName: artifactName, payload: .json(text))
    }

    static func file(
        _ file: FilePayload,
        artifactId: String? = nil,
        artifactName: String? = nil
    ) -> ResultBlock {
        ResultBlock(id: UUID(), artifactId: artifactId, artifactName: artifactName, payload: .file(file))
    }

    static func link(
        _ link: LinkPayload,
        artifactId: String? = nil,
        artifactName: String? = nil
    ) -> ResultBlock {
        ResultBlock(id: UUID(), artifactId: artifactId, artifactName: artifactName, payload: .link(link))
    }

    /// Flattened text used for legacy `summary` / persistence fallback.
    var summaryText: String {
        switch payload {
        case .markdown(let text):
            return text
        case .json(let text):
            return "```json\n\(text)\n```"
        case .file(let file):
            let name = file.filename ?? "file"
            let mime = file.mediaType ?? "application/octet-stream"
            if let preview = file.previewText, !preview.isEmpty {
                return "**\(name)** (`\(mime)`)\n\n```\n\(preview)\n```"
            }
            return "**\(name)** (`\(mime)`, \(file.byteCount) bytes)"
        case .link(let link):
            let label = link.filename ?? link.url
            return "[\(label)](\(link.url))"
        }
    }
}

enum TaskState {
    case idle, working, completed, failed

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
    var thinking: [ThinkingItem] = []
    var summary: String? = nil
    /// Structured artifact results (text / data / raw / url).
    var resultBlocks: [ResultBlock] = []
    var state: TaskState = .working
    var errorMessage: String? = nil
    var skillId: String? = nil
    var skillName: String? = nil
    let createdAt: Date

    /// In-progress text for the active artifact stream.
    var summaryBuffer = ""
    /// Already finished markdown artifacts (legacy string mirror of committed text blocks).
    var committedSummary = ""
    /// Artifact currently being streamed into `summaryBuffer`.
    var activeArtifactId: String?
    var activeArtifactName: String?

    var isSubTask: Bool { parentTaskId != nil }

    var hasResultContent: Bool {
        if let summary, !summary.isEmpty { return true }
        if !resultBlocks.isEmpty { return true }
        if !summaryBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    var hasThinking: Bool { !thinking.isEmpty }

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
