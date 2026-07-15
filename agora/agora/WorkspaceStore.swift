import Foundation
import Observation

@Observable
class WorkspaceStore {
    var backends: [Backend] = []
    var sessions: [Session] = []
    var selectedSessionId: UUID?

    private var snapshots: [UUID: SessionSnapshot] = [:]
    private var vms: [UUID: ConversationVM] = [:]
    private var agentCards: [UUID: AgentCard] = [:]
    private var agentCardErrors: [UUID: String] = [:]
    private var agentCardTasks: [UUID: Task<Void, Never>] = [:]
    private let storageKey = "agora.workspace.v1"

    init() {
        load()
        if backends.isEmpty {
            migrateFromLegacySettings()
        }
        if selectedSessionId == nil {
            selectedSessionId = sessions.first?.id
        }
    }

    func selectSession(_ id: UUID?) {
        selectedSessionId = id
        save()
    }

    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    func backend(for session: Session) -> Backend? {
        backends.first { $0.id == session.backendId }
    }

    func sessions(for backendId: UUID) -> [Session] {
        sessions
            .filter { $0.backendId == backendId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func vm(for sessionId: UUID) -> ConversationVM {
        if let existing = vms[sessionId] { return existing }
        let vm = ConversationVM()
        if let snapshot = snapshots[sessionId] {
            vm.restore(from: snapshot)
        }
        vms[sessionId] = vm
        return vm
    }

    func persistSnapshot(for sessionId: UUID) {
        guard let vm = vms[sessionId] else { return }
        snapshots[sessionId] = vm.snapshot()
        save()
    }

    // MARK: - Backend CRUD

    @discardableResult
    func addBackend(_ backend: Backend) -> Backend {
        backends.append(backend)
        let session = addSession(to: backend.id)
        selectedSessionId = session.id
        save()
        return backend
    }

    func updateBackend(_ backend: Backend) {
        guard let idx = backends.firstIndex(where: { $0.id == backend.id }) else { return }
        let previous = backends[idx]
        backends[idx] = backend
        if previous.serverURL != backend.serverURL
            || previous.requestHeaders != backend.requestHeaders {
            invalidateAgentCard(for: backend.id)
        }
        save()
    }

    func deleteBackend(_ backend: Backend) {
        let removedSessionIds = sessions.filter { $0.backendId == backend.id }.map(\.id)
        sessions.removeAll { $0.backendId == backend.id }
        backends.removeAll { $0.id == backend.id }
        for id in removedSessionIds {
            vms.removeValue(forKey: id)
            snapshots.removeValue(forKey: id)
        }
        if let selected = selectedSessionId, removedSessionIds.contains(selected) {
            selectedSessionId = sessions.first?.id
        }
        save()
    }

    // MARK: - Session CRUD

    @discardableResult
    func addSession(to backendId: UUID) -> Session {
        let session = Session(backendId: backendId)
        sessions.append(session)
        selectedSessionId = session.id
        save()
        return session
    }

    func updateSession(_ session: Session) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx] = session
        save()
    }

    func deleteSession(_ session: Session) {
        deleteSessions(ids: [session.id])
    }

    func deleteSessions(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
        for id in ids {
            vms.removeValue(forKey: id)
            snapshots.removeValue(forKey: id)
        }
        if let selected = selectedSessionId, ids.contains(selected) {
            selectedSessionId = sessions.first?.id
        }
        save()
    }

    func renameSession(_ session: Session, title: String) {
        var updated = session
        updated.title = title
        updateSession(updated)
    }

    func agentCard(for backendId: UUID) -> AgentCard? {
        agentCards[backendId]
    }

    func agentCardError(for backendId: UUID) -> String? {
        agentCardErrors[backendId]
    }

    func isLoadingAgentCard(for backendId: UUID) -> Bool {
        agentCardTasks[backendId] != nil && agentCards[backendId] == nil && agentCardErrors[backendId] == nil
    }

    func loadAgentCard(for backend: Backend) {
        let backendId = backend.id
        if agentCards[backendId] != nil { return }
        if agentCardTasks[backendId] != nil { return }

        agentCardTasks[backendId] = Task { @MainActor in
            defer { agentCardTasks[backendId] = nil }
            do {
                let url = URL(string: backend.serverURL) ?? URL(string: "http://localhost:8000")!
                let card = try await backend.makeA2AClient(baseURL: url, includeMessageMetadata: false).fetchAgentCard()
                agentCards[backendId] = card
                agentCardErrors[backendId] = nil
            } catch {
                agentCardErrors[backendId] = AgentCardErrorMessage.message(for: error, serverURL: backend.serverURL)
            }
        }
    }

    func invalidateAgentCard(for backendId: UUID) {
        agentCards.removeValue(forKey: backendId)
        agentCardErrors.removeValue(forKey: backendId)
        agentCardTasks[backendId]?.cancel()
        agentCardTasks[backendId] = nil
    }

    /// JSONRPC endpoint for messaging: prefer resolved Agent Card url, fall back to configured Server URL.
    func a2aClient(for backend: Backend) -> A2AClient {
        backend.makeA2AClient(baseURL: jsonrpcEndpointURL(for: backend))
    }

    func jsonrpcEndpointURL(for backend: Backend) -> URL {
        if let card = agentCards[backend.id], let url = URL(string: card.url) {
            return url
        }
        return URL(string: backend.serverURL) ?? URL(string: "http://localhost:8000")!
    }

    // MARK: - Persistence

    private func save() {
        let data = WorkspaceData(
            backends: backends,
            sessions: sessions,
            snapshots: snapshots,
            selectedSessionId: selectedSessionId
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    private func load() {
        guard let raw = UserDefaults.standard.data(forKey: storageKey),
              let data = try? JSONDecoder().decode(WorkspaceData.self, from: raw) else { return }
        backends = data.backends
        sessions = data.sessions
        snapshots = data.snapshots
        selectedSessionId = data.selectedSessionId
    }

    private func migrateFromLegacySettings() {
        let legacyURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8000"
        let backend = Backend(name: "Local", serverURL: legacyURL)
        backends = [backend]
        sessions = [Session(backendId: backend.id)]
        selectedSessionId = sessions.first?.id
        save()
    }
}
