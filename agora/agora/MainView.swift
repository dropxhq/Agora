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

    var body: some View {
        List(selection: Binding(
            get: { store.selectedSessionId },
            set: { store.selectSession($0) }
        )) {
            ForEach(store.backends) { backend in
                Section {
                    ForEach(store.sessions(for: backend.id)) { session in
                        Label(session.title, systemImage: "message")
                            .tag(Optional(session.id))
                            .contextMenu {
                                Button("重命名") {
                                    renameText = session.title
                                    renameTarget = session
                                }
                                Button("删除", role: .destructive) {
                                    store.deleteSession(session)
                                }
                            }
                    }
                    .onDelete { offsets in
                        deleteSessions(at: offsets, backendId: backend.id)
                    }
                } header: {
                    HStack {
                        Label(backend.name, systemImage: "server.rack")
                        Spacer()
                        Menu {
                            Button {
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
            }
        }
        .navigationTitle("Agora")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddBackend) {
                    Label("添加 Backend", systemImage: "plus")
                }
            }
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

    @State private var renameTarget: Session?
    @State private var renameText = ""

    private func deleteSessions(at offsets: IndexSet, backendId: UUID) {
        let items = store.sessions(for: backendId)
        for index in offsets {
            store.deleteSession(items[index])
        }
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
