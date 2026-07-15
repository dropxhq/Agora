import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            Color.clear.frame(height: 8)
        case .block(let markdown):
            if let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                Text(attributed)
            } else {
                Text(markdown)
            }
        case .line(let line):
            if let attributed = try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(line)
            }
        }
    }
}

private enum MarkdownSection {
    case spacer
    case line(String)
    case block(String)
}

private enum MarkdownSectionParser {
    static func parse(_ content: String) -> [MarkdownSection] {
        let lines = normalize(content).components(separatedBy: "\n")
        var sections: [MarkdownSection] = []
        var tableBuffer: [String] = []

        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            sections.append(.block(tableBuffer.joined(separator: "\n")))
            tableBuffer = []
        }

        for line in lines {
            if isTableLine(line) {
                tableBuffer.append(line)
                continue
            }

            flushTable()

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if sections.last != .spacer {
                    sections.append(.spacer)
                }
            } else {
                sections.append(.line(line))
            }
        }

        flushTable()
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
        text = text.replacingOccurrences(of: " - ", with: "\n- ")
        return text.trimmingCharacters(in: .newlines)
    }

    static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        return trimmed.filter { $0 == "|" }.count >= 2
    }
}

extension MarkdownSection: Equatable {
    static func == (lhs: MarkdownSection, rhs: MarkdownSection) -> Bool {
        switch (lhs, rhs) {
        case (.spacer, .spacer):
            return true
        case (.line(let a), .line(let b)):
            return a == b
        case (.block(let a), .block(let b)):
            return a == b
        default:
            return false
        }
    }
}
