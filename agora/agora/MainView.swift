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
            BackendEditorSheet(mode: .add) { backend in
                store.addBackend(backend)
            }
        }
        .sheet(item: $editingBackend) { backend in
            BackendEditorSheet(mode: .edit(backend)) { updated in
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
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
            for backend in store.backends {
                store.loadAgentCard(for: backend)
            }
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
                Label(backend.displayTitle, systemImage: "server.rack")
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
    let onSave: (Backend) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var backendID = UUID()
    @State private var name = ""
    @State private var nickname = ""
    @State private var serverURL = "http://localhost:8000"
    @State private var headerEntries: [KeyValueEntry] = []
    @State private var metadataEntries: [KeyValueEntry] = []
    @State private var configTab: BackendConfigTab = .headers
    @State private var isFetchingName = false
    @State private var nameFetchError: String?
    @State private var nameFetchGeneration = 0

    private enum BackendConfigTab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case metadata = "Metadata"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section("Backend") {
                        LabeledContent("名称") {
                            HStack(spacing: 8) {
                                Text(nameDisplay)
                                    .foregroundStyle(name.isEmpty ? .tertiary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .textSelection(.enabled)
                                if isFetchingName {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        TextField("昵称（可选）", text: $nickname)
                        TextField("Server URL", text: $serverURL)
                            .textContentType(.URL)
#if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
#endif
                        if let nameFetchError {
                            Text(nameFetchError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("", selection: $configTab) {
                    ForEach(BackendConfigTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView {
                    Group {
                        switch configTab {
                        case .headers:
                            KeyValueTableEditor(entries: $headerEntries, mode: .headers)
                        case .metadata:
                            KeyValueTableEditor(entries: $metadataEntries, mode: .metadata)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle(modeTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(buildBackend())
                        dismiss()
                    }
                    .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                switch mode {
                case .add:
                    backendID = UUID()
                    name = ""
                    nickname = ""
                    serverURL = "http://localhost:8000"
                    headerEntries = []
                    metadataEntries = []
                    configTab = .headers
                    nameFetchError = nil
                case .edit(let backend):
                    backendID = backend.id
                    name = backend.name
                    nickname = backend.nickname
                    serverURL = backend.serverURL
                    headerEntries = BackendConfigParser.headerEntries(from: backend.requestHeaders)
                    metadataEntries = BackendConfigParser.metadataEntries(from: backend.messageMetadata)
                    configTab = .headers
                    nameFetchError = nil
                }
                refreshNameFromAgentCard()
            }
            .onChange(of: serverURL) { _, _ in
                refreshNameFromAgentCard()
            }
        }
#if os(macOS)
        .frame(width: 680, height: 560)
#endif
    }

    private var nameDisplay: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if isFetchingName {
            return "正在从 Agent Card 获取…"
        }
        return "保存后从 Agent Card 自动获取"
    }

    private func buildBackend() -> Backend {
        Backend(
            id: backendID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            requestHeaders: BackendConfigParser.serializeHeaders(headerEntries),
            messageMetadata: BackendConfigParser.serializeMetadata(metadataEntries)
        )
    }

    private var modeTitle: String {
        switch mode {
        case .add: return "添加 Backend"
        case .edit: return "编辑 Backend"
        }
    }

    private func refreshNameFromAgentCard() {
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            return
        }

        nameFetchGeneration += 1
        let generation = nameFetchGeneration
        isFetchingName = true
        nameFetchError = nil
        let draft = buildBackend()
        Task { @MainActor in
            defer {
                if generation == nameFetchGeneration {
                    isFetchingName = false
                }
            }
            do {
                let card = try await draft.makeA2AClient(baseURL: url, includeMessageMetadata: false).fetchAgentCard()
                guard generation == nameFetchGeneration else { return }
                let cardName = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cardName.isEmpty {
                    name = cardName
                }
                nameFetchError = nil
            } catch {
                guard generation == nameFetchGeneration else { return }
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nameFetchError = "无法获取 Agent Card 名称"
                }
            }
        }
    }
}
