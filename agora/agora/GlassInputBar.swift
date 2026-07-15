import SwiftUI

struct GlassInputBar: View {
    @Binding var text: String
    var placeholder: String = "输入问题..."
    var skills: [AgentSkill] = []
    var isStreaming: Bool = false
    var isSendDisabled: Bool = false
    var onSubmit: () -> Void
    var onStop: () -> Void = {}

    @State private var inputHeight: CGFloat = MessageInputMetrics.lineHeight
    @State private var selectedIndex = 0
    @State private var dismissAutocomplete = false
    @State private var forceShowSkills = false

    private enum BarMetrics {
        static let buttonSize: CGFloat = 32
        static let sideInset: CGFloat = 6
        static let multilineHorizontalInset: CGFloat = 12
        static let multilineTopInset: CGFloat = 12
        static let multilineBottomInset: CGFloat = 8
        static let multilineCornerRadius: CGFloat = 20
        static var singleLineHeight: CGFloat { buttonSize + sideInset * 2 }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendDisabled
    }

    private var actionEnabled: Bool {
        isStreaming || canSend
    }

    /// 仅一行时用紧凑横排；多行时切到上方文本 + 下方工具栏
    private var isMultiline: Bool {
        inputHeight > MessageInputMetrics.lineHeight + 0.5
            || text.contains(where: \.isNewline)
    }

    private var singleLineShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BarMetrics.singleLineHeight / 2, style: .continuous)
    }

    private var multilineShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BarMetrics.multilineCornerRadius, style: .continuous)
    }

    private var activeQuery: SkillSlashCommand.ActiveQuery? {
        guard !dismissAutocomplete else { return nil }
        return SkillSlashCommand.activeQuery(in: text)
    }

    private var listSkills: [AgentSkill] {
        if forceShowSkills {
            return skills
        }
        guard let activeQuery else { return [] }
        return SkillSlashCommand.filteredSkills(skills, query: activeQuery.query)
    }

    private var isAutocompleteVisible: Bool {
        !listSkills.isEmpty && (forceShowSkills || activeQuery != nil)
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if isAutocompleteVisible {
                    SkillAutocompleteView(
                        skills: listSkills,
                        selectedIndex: selectedIndex
                    ) { skill in
                        acceptSelection(skill)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Group {
                    if isMultiline {
                        multilineBar
                    } else {
                        singleLineBar
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isMultiline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.15), value: isAutocompleteVisible)
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { inputHeight = MessageInputMetrics.lineHeight }
            if SkillSlashCommand.activeQuery(in: newValue) != nil {
                forceShowSkills = false
            }
            dismissAutocomplete = false
            clampSelectedIndex()
        }
        .onChange(of: listSkills.count) { _, _ in
            clampSelectedIndex()
        }
    }

    private var singleLineBar: some View {
        HStack(alignment: .center, spacing: 8) {
            plusButton
            messageInput(alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sendButton
        }
        .padding(BarMetrics.sideInset)
        .frame(minHeight: BarMetrics.singleLineHeight)
        .glassEffect(.regular.interactive(), in: singleLineShape)
    }

    private var multilineBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageInput(alignment: .topLeading)
                .frame(maxWidth: .infinity, minHeight: MessageInputMetrics.lineHeight, alignment: .topLeading)

            HStack(spacing: 8) {
                plusButton
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(.horizontal, BarMetrics.multilineHorizontalInset)
        .padding(.top, BarMetrics.multilineTopInset)
        .padding(.bottom, BarMetrics.multilineBottomInset)
        .glassEffect(.regular.interactive(), in: multilineShape)
    }

    @ViewBuilder
    private var plusButton: some View {
        if !skills.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    forceShowSkills.toggle()
                    dismissAutocomplete = false
                    selectedIndex = 0
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: BarMetrics.buttonSize, height: BarMetrics.buttonSize)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("选择 Skill")
        }
    }

    private var sendButton: some View {
        Button(action: handleAction) {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(actionEnabled ? .white : .secondary)
                .frame(width: BarMetrics.buttonSize, height: BarMetrics.buttonSize)
                .background(
                    Circle().fill(actionEnabled ? Color.accentColor : Color.secondary.opacity(0.25))
                )
        }
        .buttonStyle(.plain)
        .disabled(!actionEnabled)
        .help(isStreaming ? "停止生成" : "发送")
    }

    private func messageInput(alignment: Alignment) -> some View {
        MultilineMessageInput(
            text: $text,
            height: $inputHeight,
            placeholder: placeholder,
            onSubmit: onSubmit,
            canSend: canSend && !isStreaming,
            autocompleteActive: isAutocompleteVisible,
            onAutocompleteNavigate: { delta in
                navigateSelection(by: delta)
            },
            onAutocompleteAccept: {
                acceptHighlightedSelection()
            },
            onAutocompleteDismiss: {
                dismissSkillList()
            }
        )
        .font(.body)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func handleAction() {
        if isStreaming {
            onStop()
        } else if canSend {
            onSubmit()
        }
    }

    private func dismissSkillList() {
        dismissAutocomplete = true
        forceShowSkills = false
    }

    private func navigateSelection(by delta: Int) {
        guard !listSkills.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + listSkills.count) % listSkills.count
    }

    private func acceptHighlightedSelection() {
        guard isAutocompleteVisible, listSkills.indices.contains(selectedIndex) else { return }
        acceptSelection(listSkills[selectedIndex])
    }

    private func acceptSelection(_ skill: AgentSkill) {
        text = SkillSlashCommand.applySelection(skill, to: text)
        dismissSkillList()
        selectedIndex = 0
    }

    private func clampSelectedIndex() {
        guard !listSkills.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(selectedIndex, listSkills.count - 1)
    }
}
