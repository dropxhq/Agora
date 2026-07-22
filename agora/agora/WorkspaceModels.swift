import Foundation

struct Backend: Identifiable, Codable, Hashable {
    var id: UUID
    /// Canonical name from the A2A Agent Card (`card.name`). Synced on fetch.
    var name: String
    /// Optional user-facing label. When non-empty, sidebar shows this instead of `name`.
    var nickname: String
    var serverURL: String
    /// One header per line: `Header-Name: value`
    var requestHeaders: String
    /// JSON object merged into every user message's `metadata` field
    var messageMetadata: String

    init(
        id: UUID = UUID(),
        name: String = "",
        nickname: String = "",
        serverURL: String,
        requestHeaders: String = "",
        messageMetadata: String = ""
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.serverURL = serverURL
        self.requestHeaders = requestHeaders
        self.messageMetadata = messageMetadata
    }

    /// Sidebar / UI title: nickname if set, otherwise Agent Card name.
    var displayTitle: String {
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { return nick }
        let cardName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cardName.isEmpty { return cardName }
        return "Backend"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nickname, serverURL, requestHeaders, messageMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        serverURL = try container.decode(String.self, forKey: .serverURL)
        requestHeaders = try container.decodeIfPresent(String.self, forKey: .requestHeaders) ?? ""
        messageMetadata = try container.decodeIfPresent(String.self, forKey: .messageMetadata) ?? ""
    }
}

enum BackendConfigParser {
    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            headers[key] = value
        }
        return headers
    }

    /// Headers with `@random:*` tokens already resolved for the current request.
    static func resolvedHeaders(_ text: String) -> [String: String] {
        parseHeaders(text).mapValues { resolveStringValue($0) }
    }

    static func headerEntries(from text: String) -> [KeyValueEntry] {
        parseHeaders(text)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { KeyValueEntry.fromPersistedValue(key: $0.key, value: $0.value) }
    }

    static func serializeHeaders(_ entries: [KeyValueEntry]) -> String {
        entries
            .filter(\.isEnabled)
            .map {
                (
                    $0.key.trimmingCharacters(in: .whitespaces),
                    $0.persistedValue.trimmingCharacters(in: .whitespaces)
                )
            }
            .filter { !$0.0.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }

    static func parseMetadataJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Metadata with `@random:*` tokens already resolved for the current request.
    static func resolvedMetadataJSON(_ text: String) -> [String: Any]? {
        guard let object = parseMetadataJSON(text) else { return nil }
        var resolved: [String: Any] = [:]
        for (key, value) in object {
            resolved[key] = resolveJSONValue(value)
        }
        return resolved
    }

    static func metadataEntries(from text: String) -> [KeyValueEntry] {
        guard let object = parseMetadataJSON(text) else { return [] }
        return object
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let (valueType, stringValue) = inferValueType(value)
                return KeyValueEntry.fromPersistedValue(key: key, value: stringValue, valueType: valueType)
            }
    }

    static func serializeMetadata(_ entries: [KeyValueEntry]) -> String {
        var object: [String: Any] = [:]
        for entry in entries where entry.isEnabled {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            switch entry.valueMode {
            case .random:
                // Persist the token so it can be re-resolved on each request.
                object[key] = entry.randomKind.token
            case .staticValue:
                object[key] = typedJSONValue(type: entry.valueType, text: entry.value)
            }
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func resolveStringValue(_ text: String) -> String {
        if let kind = RandomValueKind.parse(token: text) {
            return kind.generateString()
        }
        return text
    }

    static func resolveJSONValue(_ value: Any) -> Any {
        guard let string = value as? String,
              let kind = RandomValueKind.parse(token: string) else {
            return value
        }
        return kind.generateJSONValue()
    }

    private static func inferValueType(_ value: Any) -> (KeyValueFieldType, String) {
        switch value {
        case let string as String:
            return (.string, string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return (.boolean, number.boolValue ? "true" : "false")
            }
            return (.number, number.stringValue)
        case is NSNull:
            return (.string, "null")
        default:
            return (.string, jsonValueToString(value))
        }
    }

    private static func typedJSONValue(type: KeyValueFieldType, text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .string:
            return trimmed
        case .number:
            if let intValue = Int(trimmed) { return intValue }
            if let doubleValue = Double(trimmed) { return doubleValue }
            return trimmed
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return trimmed
            }
        }
    }

    private static func jsonValueToString(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case is NSNull:
            return "null"
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: value)
        }
    }

    private static func jsonValue(from text: String) -> Any {
        typedJSONValue(type: .string, text: text)
    }
}

extension Backend {
    var parsedRequestHeaders: [String: String] {
        BackendConfigParser.resolvedHeaders(requestHeaders)
    }

    var parsedMessageMetadata: [String: Any]? {
        BackendConfigParser.resolvedMetadataJSON(messageMetadata)
    }

    func makeA2AClient(baseURL: URL, includeMessageMetadata: Bool = true) -> A2AClient {
        A2AClient(
            baseURL: baseURL,
            requestHeaders: parsedRequestHeaders,
            messageMetadata: includeMessageMetadata ? parsedMessageMetadata : nil
        )
    }
}

struct Session: Identifiable, Codable, Hashable {
    var id: UUID
    var backendId: UUID
    var title: String
    var contextId: String
    var createdAt: Date

    init(id: UUID = UUID(), backendId: UUID, title: String = "新会话", contextId: String = UUID().uuidString) {
        self.id = id
        self.backendId = backendId
        self.title = title
        self.contextId = contextId
        self.createdAt = Date()
    }
}

struct PersistedToolResult: Codable {
    var id: String?
    var tool: String
    var result: String
    var ok: Bool
}

struct PersistedToolCall: Codable {
    var id: String?
    var tool: String
    var desc: String?
    var args: [String: JSONValue]
    var result: PersistedToolResult?
}

struct PersistedThinkingItem: Codable {
    var kind: String // "reasoning" | "tool_call"
    var text: String?
    var toolCall: PersistedToolCall?
}

/// Legacy persisted round shape (migration only).
struct PersistedRound: Codable {
    var reasoning: String?
    var toolCalls: [LegacyPersistedToolCall]
    var toolResults: [LegacyPersistedToolResult]
}

struct LegacyPersistedToolCall: Codable {
    var name: String?
    var args: [String: JSONValue]?
}

struct LegacyPersistedToolResult: Codable {
    var name: String?
    var result: String?
    var ok: Bool?
}

struct PersistedTask: Codable, Identifiable {
    var id: String
    var prompt: String
    var skillId: String?
    var skillName: String?
    var thinking: [PersistedThinkingItem]?
    /// Legacy field — flattened into `thinking` on restore.
    var rounds: [PersistedRound]?
    var summary: String?
    var resultBlocks: [ResultBlock]?
    var state: String
    var errorMessage: String?
    var createdAt: Date
}

struct SessionSnapshot: Codable {
    var tasks: [PersistedTask]?
    var selectedTaskId: String?
    var activeMainTaskId: String?

    // Legacy single-task fields (migration)
    var rounds: [PersistedRound]?
    var thinking: [PersistedThinkingItem]?
    var summary: String?
    var state: String?
    var errorMessage: String?
}

struct WorkspaceData: Codable {
    var backends: [Backend]
    var sessions: [Session]
    var snapshots: [UUID: SessionSnapshot]
    var selectedSessionId: UUID?
}
