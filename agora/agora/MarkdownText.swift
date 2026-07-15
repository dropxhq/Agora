import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(content)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .spacer:
            Color.clear.frame(height: 4)

        case .heading(let level, let text):
            InlineMarkdownText(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 4 : 0)

        case .paragraph(let text):
            InlineMarkdownText(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                InlineMarkdownText(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                        InlineMarkdownText(item)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        InlineMarkdownText(item)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowView(headers, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                rowView(padded(row), isHeader: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    private func padded(_ row: [String]) -> [String] {
        if row.count >= headers.count { return Array(row.prefix(headers.count)) }
        return row + Array(repeating: "", count: headers.count - row.count)
    }

    private func rowView(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineMarkdownText(cell)
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                if index < cells.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1)
                }
            }
        }
    }
}

private enum MarkdownBlock: Equatable {
    case spacer
    case heading(level: Int, text: String)
    case paragraph(String)
    case blockquote(String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(String)
    case table(headers: [String], rows: [[String]])
}

private enum MarkdownBlockParser {
    static func parse(_ content: String) -> [MarkdownBlock] {
        let lines = normalize(content).components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if blocks.last != .spacer {
                    blocks.append(.spacer)
                }
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let (block, next) = readCodeBlock(lines, start: index)
                blocks.append(block)
                index = next
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isTableHeaderPair(lines, at: index) {
                let (block, next) = readTable(lines, start: index)
                blocks.append(block)
                index = next
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                let (block, next) = readBlockquote(lines, start: index)
                blocks.append(block)
                index = next
                continue
            }

            if unorderedMarker(trimmed) != nil {
                let (block, next) = readUnorderedList(lines, start: index)
                blocks.append(block)
                index = next
                continue
            }

            if orderedMarker(trimmed) != nil {
                let (block, next) = readOrderedList(lines, start: index)
                blocks.append(block)
                index = next
                continue
            }

            let (block, next) = readParagraph(lines, start: index)
            blocks.append(block)
            index = next
        }

        while blocks.first == .spacer { blocks.removeFirst() }
        while blocks.last == .spacer { blocks.removeLast() }
        return blocks
    }

    static func normalize(_ content: String) -> String {
        var text = content
        // Unwrap JSON-style escaped newlines when the whole payload is one line.
        if !text.contains("\n"), text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        return .heading(level: level, text: String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedMarker(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) { return prefix }
        }
        return nil
    }

    private static func orderedMarker(_ trimmed: String) -> String? {
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let number = trimmed[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let after = trimmed[trimmed.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return String(trimmed[..<after.startIndex]) + " "
    }

    private static func isTableHeaderPair(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return isTableRow(header) && isSeparatorRow(separator)
    }

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.contains("|") && trimmed.filter { $0 == "|" }.count >= 1
    }

    private static func isSeparatorRow(_ trimmed: String) -> Bool {
        guard isTableRow(trimmed) else { return false }
        let cells = splitTableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let cleaned = cell
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            return cleaned.isEmpty && cell.contains("-")
        }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func readTable(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        let headers = splitTableCells(lines[start])
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !isTableRow(trimmed) || isSeparatorRow(trimmed) { break }
            rows.append(splitTableCells(trimmed))
            index += 1
        }
        return (.table(headers: headers, rows: rows), index)
    }

    private static func readCodeBlock(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start + 1
        var body: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                return (.codeBlock(body.joined(separator: "\n")), index + 1)
            }
            body.append(lines[index])
            index += 1
        }
        return (.codeBlock(body.joined(separator: "\n")), index)
    }

    private static func readBlockquote(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var parts: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("> ") {
                parts.append(String(trimmed.dropFirst(2)))
            } else if trimmed == ">" {
                parts.append("")
            } else {
                break
            }
            index += 1
        }
        return (.blockquote(parts.joined(separator: "\n")), index)
    }

    private static func readUnorderedList(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var items: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let marker = unorderedMarker(trimmed) else { break }
            items.append(String(trimmed.dropFirst(marker.count)))
            index += 1
        }
        return (.unorderedList(items), index)
    }

    private static func readOrderedList(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var items: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let marker = orderedMarker(trimmed) else { break }
            items.append(String(trimmed.dropFirst(marker.count)))
            index += 1
        }
        return (.orderedList(items), index)
    }

    private static func readParagraph(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var parts: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix("```") { break }
            if parseHeading(trimmed) != nil { break }
            if isTableHeaderPair(lines, at: index) { break }
            if trimmed.hasPrefix("> ") || trimmed == ">" { break }
            if unorderedMarker(trimmed) != nil { break }
            if orderedMarker(trimmed) != nil { break }
            parts.append(trimmed)
            index += 1
        }
        return (.paragraph(parts.joined(separator: " ")), index)
    }
}
