import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sections: [MarkdownSection] {
        MarkdownSectionParser.parse(content)
    }

    @ViewBuilder
    private func sectionView(_ section: MarkdownSection) -> some View {
        switch section {
        case .spacer:
            Color.clear.frame(height: 4)
        case .markdown(let markdown):
            if let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum MarkdownSection {
    case spacer
    case markdown(String)
}

/// Splits content so tables stay isolated, while headings / lists / paragraphs
/// are rendered together with full Markdown block syntax.
private enum MarkdownSectionParser {
    static func parse(_ content: String) -> [MarkdownSection] {
        let lines = normalize(content).components(separatedBy: "\n")
        var sections: [MarkdownSection] = []
        var proseBuffer: [String] = []
        var tableBuffer: [String] = []

        func flushProse() {
            let joined = proseBuffer.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            proseBuffer = []
            guard !joined.isEmpty else { return }
            sections.append(.markdown(joined))
        }

        func flushTable() {
            let joined = tableBuffer.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            tableBuffer = []
            guard !joined.isEmpty else { return }
            sections.append(.markdown(joined))
        }

        for line in lines {
            if isTableLine(line) {
                flushProse()
                tableBuffer.append(line)
                continue
            }

            flushTable()

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !proseBuffer.isEmpty {
                    flushProse()
                    sections.append(.spacer)
                }
            } else {
                proseBuffer.append(line)
            }
        }

        flushTable()
        flushProse()
        return sections
    }

    static func normalize(_ content: String) -> String {
        var text = content
        if !text.contains("\n"), text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
        }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Some servers inline section markers without newlines.
        for marker in ["\n\n📋", "\n\n📊", "\n\n💡", "\n\n✅", "\n\n---", "\n\n——"] {
            let token = String(marker.dropFirst(2))
            text = text.replacingOccurrences(of: token, with: marker)
        }

        // Ensure ATX headings start on their own line when jammed mid-string.
        text = text.replacingOccurrences(
            of: #"([^\n])(#{1,6}\s+)"#,
            with: "$1\n$2",
            options: .regularExpression
        )

        // Keep list items on their own lines when streamed inline.
        text = text.replacingOccurrences(of: " - ", with: "\n- ")
        text = text.replacingOccurrences(of: "\n|", with: "\n|")

        return text.trimmingCharacters(in: .newlines)
    }

    static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        // Separator row: | --- | --- |
        let stripped = trimmed
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if stripped.isEmpty { return true }
        return trimmed.filter { $0 == "|" }.count >= 2
    }
}

extension MarkdownSection: Equatable {
    static func == (lhs: MarkdownSection, rhs: MarkdownSection) -> Bool {
        switch (lhs, rhs) {
        case (.spacer, .spacer):
            return true
        case (.markdown(let a), .markdown(let b)):
            return a == b
        default:
            return false
        }
    }
}
