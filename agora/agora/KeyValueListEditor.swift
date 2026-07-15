import SwiftUI

enum KeyValueFieldType: String, CaseIterable, Identifiable {
    case string
    case number
    case boolean

    var id: String { rawValue }
    var label: String { rawValue }
}

struct KeyValueEntry: Identifiable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var key: String
    var valueType: KeyValueFieldType
    var value: String
    var note: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        key: String = "",
        valueType: KeyValueFieldType = .string,
        value: String = "",
        note: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.key = key
        self.valueType = valueType
        self.value = value
        self.note = note
    }
}

enum KeyValueTableMode {
    case headers
    case metadata

    var footer: String {
        switch self {
        case .headers:
            return "附加到所有请求（含 Agent Card），用于鉴权等。"
        case .metadata:
            return "合并到每条 user message 的 metadata 字段。"
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

            tableField(
                placeholder: "值",
                text: binding(for: entry.id, keyPath: \.value),
                flexible: true
            )

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
