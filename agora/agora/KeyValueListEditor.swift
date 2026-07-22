import SwiftUI

enum KeyValueFieldType: String, CaseIterable, Identifiable {
    case string
    case number
    case boolean

    var id: String { rawValue }
    var label: String { rawValue }
}

enum KeyValueValueMode: String, CaseIterable, Identifiable {
    case staticValue
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .staticValue: return "静态"
        case .random: return "随机"
        }
    }
}

enum RandomValueKind: String, CaseIterable, Identifiable {
    case uuid
    case int
    case hex16
    case alnum12

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uuid: return "UUID"
        case .int: return "整数"
        case .hex16: return "Hex"
        case .alnum12: return "字符串"
        }
    }

    /// Persisted token written into header/metadata value fields.
    var token: String {
        switch self {
        case .uuid: return "@random:uuid"
        case .int: return "@random:int"
        case .hex16: return "@random:hex:16"
        case .alnum12: return "@random:alnum:12"
        }
    }

    static func parse(token: String) -> RandomValueKind? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "@random:uuid": return .uuid
        case "@random:int": return .int
        case "@random:hex:16", "@random:hex": return .hex16
        case "@random:alnum:12", "@random:alnum", "@random:string": return .alnum12
        default: return nil
        }
    }

    func generateString() -> String {
        switch self {
        case .uuid:
            return UUID().uuidString
        case .int:
            return String(Int.random(in: 0...999_999_999))
        case .hex16:
            let chars = Array("0123456789abcdef")
            return String((0..<16).map { _ in chars.randomElement()! })
        case .alnum12:
            let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return String((0..<12).map { _ in chars.randomElement()! })
        }
    }

    func generateJSONValue() -> Any {
        switch self {
        case .int:
            return Int.random(in: 0...999_999_999)
        case .uuid, .hex16, .alnum12:
            return generateString()
        }
    }
}

struct KeyValueEntry: Identifiable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var key: String
    var valueType: KeyValueFieldType
    var valueMode: KeyValueValueMode
    var randomKind: RandomValueKind
    var value: String
    var note: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        key: String = "",
        valueType: KeyValueFieldType = .string,
        valueMode: KeyValueValueMode = .staticValue,
        randomKind: RandomValueKind = .uuid,
        value: String = "",
        note: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.key = key
        self.valueType = valueType
        self.valueMode = valueMode
        self.randomKind = randomKind
        self.value = value
        self.note = note
    }

    /// Value written to storage (static text or random token).
    var persistedValue: String {
        switch valueMode {
        case .staticValue:
            return value
        case .random:
            return randomKind.token
        }
    }

    static func fromPersistedValue(
        key: String,
        value: String,
        valueType: KeyValueFieldType = .string,
        note: String = ""
    ) -> KeyValueEntry {
        if let kind = RandomValueKind.parse(token: value) {
            return KeyValueEntry(
                key: key,
                valueType: valueType,
                valueMode: .random,
                randomKind: kind,
                value: "",
                note: note
            )
        }
        return KeyValueEntry(key: key, valueType: valueType, value: value, note: note)
    }
}

enum KeyValueTableMode {
    case headers
    case metadata

    var footer: String {
        switch self {
        case .headers:
            return "附加到所有请求（含 Agent Card），用于鉴权等。随机值在每次请求时重新生成。"
        case .metadata:
            return "合并到每条 user message 的 metadata 字段。随机值在每次请求时重新生成。"
        }
    }
}

struct KeyValueTableEditor: View {
    @Binding var entries: [KeyValueEntry]
    var mode: KeyValueTableMode

    private let rowHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            table
            Text(mode.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()

            ForEach(entries) { entry in
                tableRow(for: entry)
                Divider()
            }

            addParameterRow
        }
        .background(tableBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 32)
            headerCell("参数名", width: nameColumnWidth)
            if showsTypeColumn {
                headerCell("类型", width: 88)
            }
            headerCell("值", flexible: true)
            headerCell("说明", width: 120)
            Color.clear.frame(width: 32)
        }
        .frame(height: 32)
        .background(Color.primary.opacity(0.04))
    }

    private func tableRow(for entry: KeyValueEntry) -> some View {
        HStack(spacing: 0) {
            enableToggle(for: entry.id)
                .frame(width: 32)

            tableField(
                placeholder: "参数名",
                text: binding(for: entry.id, keyPath: \.key),
                width: nameColumnWidth
            )

            if showsTypeColumn {
                typePicker(for: entry.id)
                    .frame(width: 88)
                    .padding(.horizontal, 6)
            }

            valueEditor(for: entry)
                .frame(maxWidth: .infinity, alignment: .leading)

            tableField(
                placeholder: "说明",
                text: binding(for: entry.id, keyPath: \.note),
                width: 120
            )

            Button {
                entries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 32)
            .help("删除")
        }
        .frame(minHeight: rowHeight)
        .opacity(entry.isEnabled ? 1 : 0.45)
    }

    private var addParameterRow: some View {
        Button {
            entries.append(KeyValueEntry())
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: 32)
                Text("添加参数")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                Color.clear.frame(width: trailingPaddingWidth)
            }
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func enableToggle(for id: UUID) -> some View {
#if os(macOS)
        Toggle("", isOn: binding(for: id, keyPath: \.isEnabled))
            .labelsHidden()
            .toggleStyle(.checkbox)
#else
        Toggle("", isOn: binding(for: id, keyPath: \.isEnabled))
            .labelsHidden()
#endif
    }

    private var showsTypeColumn: Bool {
        mode == .metadata
    }

    private var nameColumnWidth: CGFloat {
        showsTypeColumn ? 140 : 160
    }

    private var trailingPaddingWidth: CGFloat {
        32 + (showsTypeColumn ? 88 : 0) + 120
    }

    private var tableBackground: Color {
#if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.35)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }

    private func headerCell(_ title: String, width: CGFloat? = nil, flexible: Bool = false) -> some View {
        Group {
            if flexible {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(title)
                    .frame(width: width, alignment: .leading)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func tableField(
        placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil,
        flexible: Bool = false
    ) -> some View {
        let field = TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif

        if flexible {
            field.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            field.frame(width: width, alignment: .leading)
        }
    }

    private func valueEditor(for entry: KeyValueEntry) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: binding(for: entry.id, keyPath: \.valueMode)) {
                ForEach(KeyValueValueMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 64, alignment: .leading)

            if entry.valueMode == .staticValue {
                TextField("值", text: binding(for: entry.id, keyPath: \.value))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
            } else {
                Picker("", selection: binding(for: entry.id, keyPath: \.randomKind)) {
                    ForEach(RandomValueKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .font(.callout)
    }

    private func typePicker(for id: UUID) -> some View {
        Picker("", selection: binding(for: id, keyPath: \.valueType)) {
            ForEach(KeyValueFieldType.allCases) { type in
                Text(type.label).tag(type)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(.callout)
    }

    private func binding<T>(for id: UUID, keyPath: WritableKeyPath<KeyValueEntry, T>) -> Binding<T> {
        Binding(
            get: { entries.first(where: { $0.id == id })?[keyPath: keyPath] ?? KeyValueEntry()[keyPath: keyPath] },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index][keyPath: keyPath] = newValue
            }
        )
    }
}
