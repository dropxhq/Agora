import SwiftUI

struct SkillAutocompleteView: View {
    let skills: [AgentSkill]
    let selectedIndex: Int
    var onSelect: (AgentSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                Button {
                    onSelect(skill)
                } label: {
                    SkillAutocompleteRow(skill: skill, isSelected: index == selectedIndex)
                }
                .buttonStyle(.plain)

                if index < skills.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct SkillAutocompleteRow: View {
    let skill: AgentSkill
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("/\(skill.id)")
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
    }
}
