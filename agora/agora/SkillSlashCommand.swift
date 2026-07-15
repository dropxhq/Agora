import Foundation

enum SkillSlashCommand {
    struct OutgoingMessage: Equatable {
        let text: String
        let skill: AgentSkill?
        let rawInput: String
    }

    struct ActiveQuery: Equatable {
        let query: String
    }

    /// Returns the filter query when the input is an in-progress slash command (`/…` with no space yet).
    static func activeQuery(in text: String) -> ActiveQuery? {
        guard text.hasPrefix("/") else { return nil }
        guard !text.dropFirst().contains(where: { $0.isWhitespace }) else { return nil }
        return ActiveQuery(query: String(text.dropFirst()))
    }

    static func filteredSkills(_ skills: [AgentSkill], query: String) -> [AgentSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        let needle = trimmed.lowercased()
        return skills.filter { skill in
            skill.id.lowercased().contains(needle)
                || skill.name.lowercased().contains(needle)
                || skill.tags?.contains(where: { $0.lowercased().contains(needle) }) == true
        }
    }

    static func applySelection(_ skill: AgentSkill, to text: String) -> String {
        let example = skill.examples?.first
        if let example, !example.isEmpty {
            return "/\(skill.id) \(example)"
        }
        return "/\(skill.id) "
    }

    static func prepareOutgoing(from text: String, skills: [AgentSkill]) -> OutgoingMessage {
        OutgoingMessage(
            text: resolveOutgoingMessage(from: text, skills: skills),
            skill: matchedSkill(from: text, in: skills),
            rawInput: text
        )
    }

    static func matchedSkill(from text: String, in skills: [AgentSkill]) -> AgentSkill? {
        guard text.hasPrefix("/") else { return nil }
        let body = String(text.dropFirst())
        if let spaceIndex = body.firstIndex(where: { $0.isWhitespace }) {
            let token = String(body[..<spaceIndex])
            return matchingSkill(forToken: token, in: skills)
        }
        return matchingSkill(forToken: body, in: skills)
    }

    static func resolveOutgoingMessage(from text: String, skills: [AgentSkill]) -> String {
        guard text.hasPrefix("/") else { return text }
        let body = String(text.dropFirst())
        guard let spaceIndex = body.firstIndex(where: { $0.isWhitespace }) else {
            if let skill = matchingSkill(forToken: body, in: skills) {
                if let example = skill.examples?.first, !example.isEmpty { return example }
                return skill.description
            }
            return text
        }

        let token = String(body[..<spaceIndex])
        let rest = String(body[body.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = matchingSkill(forToken: token, in: skills) else { return text }
        if !rest.isEmpty { return rest }
        if let example = skill.examples?.first, !example.isEmpty { return example }
        return skill.description
    }

    private static func matchingSkill(forToken token: String, in skills: [AgentSkill]) -> AgentSkill? {
        let lowered = token.lowercased()
        return skills.first { $0.id.lowercased() == lowered || $0.name.lowercased() == lowered }
    }
}
