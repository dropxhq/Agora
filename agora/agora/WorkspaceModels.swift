import Foundation

struct Backend: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var serverURL: String

    init(id: UUID = UUID(), name: String, serverURL: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
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

struct PersistedToolCall: Codable {
    var name: String
    var args: [String: JSONValue]
}

struct PersistedToolResult: Codable {
    var name: String
    var result: String
    var ok: Bool
}

struct PersistedRound: Codable {
    var reasoning: String?
    var toolCalls: [PersistedToolCall]
    var toolResults: [PersistedToolResult]
}

struct PersistedTask: Codable, Identifiable {
    var id: String
    var prompt: String
    var parentTaskId: String?
    var subtaskIndex: Int?
    var rounds: [PersistedRound]
    var summary: String?
    var state: String
    var errorMessage: String?
    var createdAt: Date
}

struct SessionSnapshot: Codable {
    var tasks: [PersistedTask]?
    var selectedTaskId: String?
    var activeMainTaskId: String?
    var selectedSubTaskId: String?

    // Legacy single-task fields (migration)
    var rounds: [PersistedRound]?
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
