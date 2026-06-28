import SwiftUI

struct GlassInputBar: View {
    @Binding var text: String
    var placeholder: String = "输入问题..."
    var skills: [AgentSkill] = []
    var isSendDisabled: Bool = false
    var onSubmit: () -> Void

    @State private var inputHeight: CGFloat = MessageInputMetrics.lineHeight
    @State private var selectedIndex = 0
    @State private var dismissAutocomplete = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendDisabled
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private var activeQuery: SkillSlashCommand.ActiveQuery? {
        guard !dismissAutocomplete else { return nil }
        return SkillSlashCommand.activeQuery(in: text)
    }

    private var filteredSkills: [AgentSkill] {
        guard let activeQuery else { return [] }
        return SkillSlashCommand.filteredSkills(skills, query: activeQuery.query)
    }

    private var isAutocompleteVisible: Bool {
        activeQuery != nil && !filteredSkills.isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if isAutocompleteVisible {
                    SkillAutocompleteView(
                        skills: filteredSkills,
                        selectedIndex: selectedIndex
                    ) { skill in
                        acceptSelection(skill)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                MultilineMessageInput(
                    text: $text,
                    height: $inputHeight,
                    placeholder: placeholder,
                    onSubmit: onSubmit,
                    canSend: canSend,
                    autocompleteActive: isAutocompleteVisible,
                    onAutocompleteNavigate: { delta in
                        navigateSelection(by: delta)
                    },
                    onAutocompleteAccept: {
                        acceptHighlightedSelection()
                    },
                    onAutocompleteDismiss: {
                        dismissAutocomplete = true
                    }
                )
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, MessageInputMetrics.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .glassEffect(.regular.interactive(), in: inputShape)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.15), value: isAutocompleteVisible)
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { inputHeight = MessageInputMetrics.lineHeight }
            dismissAutocomplete = false
            clampSelectedIndex()
        }
        .onChange(of: filteredSkills.count) { _, _ in
            clampSelectedIndex()
        }
    }

    private func navigateSelection(by delta: Int) {
        guard !filteredSkills.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filteredSkills.count) % filteredSkills.count
    }

    private func acceptHighlightedSelection() {
        guard isAutocompleteVisible, filteredSkills.indices.contains(selectedIndex) else { return }
        acceptSelection(filteredSkills[selectedIndex])
    }

    private func acceptSelection(_ skill: AgentSkill) {
        text = SkillSlashCommand.applySelection(skill, to: text)
        dismissAutocomplete = true
        selectedIndex = 0
    }

    private func clampSelectedIndex() {
        guard !filteredSkills.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(selectedIndex, filteredSkills.count - 1)
    }
}
