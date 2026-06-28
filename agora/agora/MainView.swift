import SwiftUI

struct MainView: View {
    @State private var store = WorkspaceStore()
    @State private var showAddBackend = false
    @State private var editingBackend: Backend?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                onAddBackend: { showAddBackend = true },
                onEditBackend: { editingBackend = $0 }
            )
        } detail: {
            if let session = store.selectedSession,
               let backend = store.backend(for: session) {
                ConversationView(
                    store: store,
                    session: session,
                    backend: backend,
                    onEditBackend: { editingBackend = backend }
                )
            } else {
                ContentUnavailableView(
                    "选择或新建会话",
                    systemImage: "message",
                    description: Text("在左侧选择一个 backend 下的会话，或新建 backend / 会话。")
                )
            }
        }
        .sheet(isPresented: $showAddBackend) {
            BackendEditorSheet(mode: .add) { name, url in
                store.addBackend(name: name, serverURL: url)
            }
        }
        .sheet(item: $editingBackend) { backend in
            BackendEditorSheet(mode: .edit(backend)) { name, url in
                var updated = backend
                updated.name = name
                updated.serverURL = url
                store.updateBackend(updated)
            }
        }
    }
}

struct SidebarView: View {
    let store: WorkspaceStore
    let onAddBackend: () -> Void
    let onEditBackend: (Backend) -> Void

    @State private var selectedSessionIds: Set<UUID> = []
    @State private var collapsedBackendIds: Set<UUID> = []
    @State private var renameTarget: Session?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selectedSessionIds) {
            ForEach(store.backends) { backend in
                Section {
                    if !isCollapsed(backend.id) {
                        ForEach(store.sessions(for: backend.id)) { session in
                            Label(session.title, systemImage: "message")
                                .tag(session.id)
                                .contextMenu {
                                    sessionContextMenu(for: session)
                                }
                        }
                        .onDelete { offsets in
                            deleteSessions(at: offsets, backendId: backend.id)
                        }

                        Button {
                            store.addSession(to: backend.id)
                        } label: {
                            Label("新建会话", systemImage: "plus.message")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    backendSectionHeader(for: backend)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Agora")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddBackend) {
                    Label("添加 Backend", systemImage: "plus")
                }
            }
        }
        .onAppear {
            syncSelectionFromStore()
        }
        .onChange(of: store.selectedSessionId) { _, newId in
            syncSelectionFromStore(preferredId: newId)
        }
        .onChange(of: selectedSessionIds) { oldValue, newValue in
            handleSelectionChange(from: oldValue, to: newValue)
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("确定") {
                if let session = renameTarget {
                    store.renameSession(session, title: renameText)
                }
                renameTarget = nil
            }
        }
    }

    @ViewBuilder
    private func backendSectionHeader(for backend: Backend) -> some View {
        HStack(spacing: 6) {
            Button {
                toggleCollapse(for: backend.id)
            } label: {
                Image(systemName: isCollapsed(backend.id) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Button {
                toggleCollapse(for: backend.id)
            } label: {
                Label(backend.name, systemImage: "server.rack")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button {
                    if isCollapsed(backend.id) {
                        collapsedBackendIds.remove(backend.id)
                    }
                    store.addSession(to: backend.id)
                } label: {
                    Label("新建会话", systemImage: "plus.message")
                }
                Button {
                    onEditBackend(backend)
                } label: {
                    Label("编辑 Backend", systemImage: "pencil")
                }
                if store.backends.count > 1 {
                    Button("删除 Backend", role: .destructive) {
                        store.deleteBackend(backend)
                        collapsedBackendIds.remove(backend.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        if isBatchDeleteContext(for: session) {
            Button("删除 \(selectedSessionIds.count) 个会话", role: .destructive) {
                deleteSelectedSessions()
            }
        } else {
            Button("重命名") {
                renameText = session.title
                renameTarget = session
            }
            Button("删除", role: .destructive) {
                store.deleteSession(session)
                selectedSessionIds.remove(session.id)
            }
        }
    }

    private func isCollapsed(_ backendId: UUID) -> Bool {
        collapsedBackendIds.contains(backendId)
    }

    private func toggleCollapse(for backendId: UUID) {
        if collapsedBackendIds.contains(backendId) {
            collapsedBackendIds.remove(backendId)
        } else {
            collapsedBackendIds.insert(backendId)
        }
    }

    private func isBatchDeleteContext(for session: Session) -> Bool {
        selectedSessionIds.count > 1 && selectedSessionIds.contains(session.id)
    }

    private func syncSelectionFromStore(preferredId: UUID? = nil) {
        let id = preferredId ?? store.selectedSessionId
        guard let id else {
            selectedSessionIds = []
            return
        }
        if selectedSessionIds.count <= 1 {
            selectedSessionIds = [id]
        } else if !selectedSessionIds.contains(id) {
            selectedSessionIds.insert(id)
        }
    }

    private func handleSelectionChange(from oldValue: Set<UUID>, to newValue: Set<UUID>) {
        guard newValue != oldValue else { return }

        if newValue.isEmpty {
            return
        }

        if newValue.count == 1, let id = newValue.first {
            if store.selectedSessionId != id {
                store.selectSession(id)
            }
            return
        }

        let added = newValue.subtracting(oldValue)
        if added.count == 1, let id = added.first {
            store.selectSession(id)
        } else if let current = store.selectedSessionId, !newValue.contains(current) {
            store.selectSession(newValue.first)
        }
    }

    private func deleteSelectedSessions() {
        let ids = selectedSessionIds
        store.deleteSessions(ids: ids)
        selectedSessionIds.subtract(ids)
        syncSelectionFromStore()
    }

    private func deleteSessions(at offsets: IndexSet, backendId: UUID) {
        let items = store.sessions(for: backendId)
        let ids = Set(offsets.map { items[$0].id })
        store.deleteSessions(ids: ids)
        selectedSessionIds.subtract(ids)
        syncSelectionFromStore()
    }
}

private struct BackendEditorSheet: View {
    enum Mode: Identifiable {
        case add
        case edit(Backend)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let b): return b.id.uuidString
            }
        }
    }

    let mode: Mode
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var serverURL = "http://localhost:8000"

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("名称", text: $name)
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
#if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
#endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle(modeTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                               serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                switch mode {
                case .add:
                    name = "Backend \(Int.random(in: 1...99))"
                case .edit(let backend):
                    name = backend.name
                    serverURL = backend.serverURL
                }
            }
        }
#if os(macOS)
        .frame(width: 420, height: 180)
#endif
    }

    private var modeTitle: String {
        switch mode {
        case .add: return "添加 Backend"
        case .edit: return "编辑 Backend"
        }
    }
}
