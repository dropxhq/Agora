import SwiftUI

struct ResultBlocksView: View {
    let blocks: [ResultBlock]
    var liveMarkdown: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if index > 0 {
                    Divider().opacity(0.35)
                }
                ResultBlockView(block: block)
            }

            if let liveMarkdown,
               !liveMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !blocks.isEmpty {
                    Divider().opacity(0.35)
                }
                MarkdownText(content: liveMarkdown)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResultBlockView: View {
    let block: ResultBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = block.artifactName, !name.isEmpty {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            switch block.payload {
            case .markdown(let text):
                MarkdownText(content: text)
                    .font(.body)
                    .foregroundStyle(.primary)
            case .json(let text):
                JSONBlockView(text: text)
            case .file(let file):
                FileBlockView(file: file)
            case .link(let link):
                LinkBlockView(link: link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct JSONBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("data", systemImage: "curlybraces")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct FileBlockView: View {
    let file: ResultBlock.FilePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename ?? "file")
                        .font(.subheadline.weight(.semibold))
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: file.isImage ? "photo" : file.isCSV ? "tablecells" : "doc")
            }

            if file.isImage, let data = file.imageData {
                ArtifactImageView(data: data)
            } else if file.isCSV, let preview = file.previewText, !preview.isEmpty,
                      let table = CSVTable.parse(preview), !table.rows.isEmpty {
                CSVTableView(table: table)
            } else if let preview = file.previewText, !preview.isEmpty {
                Text(preview)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String {
        let mime = file.mediaType ?? "application/octet-stream"
        return "\(mime) · \(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))"
    }
}

/// Parsed CSV matrix (first row is treated as header when present).
private struct CSVTable: Sendable {
    let rows: [[String]]

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    func cell(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else {
            return ""
        }
        return rows[row][column]
    }

    nonisolated static func parse(_ text: String) -> CSVTable? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else { return nil }

        let parsed = lines.map(parseLine)
        let width = parsed.map(\.count).max() ?? 0
        guard width > 0 else { return nil }

        let normalized = parsed.map { row -> [String] in
            if row.count == width { return row }
            if row.count < width {
                return row + Array(repeating: "", count: width - row.count)
            }
            return Array(row.prefix(width))
        }
        return CSVTable(rows: normalized)
    }

    /// RFC 4180–style field split: commas outside quotes; `""` → `"`.
    nonisolated private static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let ch = line[index]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }
}

private struct CSVTableView: View {
    let table: CSVTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(table.rows.indices), id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { columnIndex in
                            let value = table.cell(row: rowIndex, column: columnIndex)
                            Text(value.isEmpty ? "—" : value)
                                .font(rowIndex == 0 ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(.primary.opacity(value.isEmpty ? 0.35 : 1))
                                .textSelection(.enabled)
                                .frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }

                    if rowIndex < table.rows.count - 1 {
                        GridRow {
                            Divider()
                                .opacity(rowIndex == 0 ? 0.55 : 0.25)
                                .gridCellColumns(table.columnCount)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LinkBlockView: View {
    let link: ResultBlock.LinkPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let filename = link.filename, !filename.isEmpty {
                        Text(filename)
                            .font(.subheadline.weight(.semibold))
                    }
                    if let url = URL(string: link.url) {
                        Link(link.url, destination: url)
                            .font(.callout)
                            .textSelection(.enabled)
                    } else {
                        Text(link.url)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let mime = link.mediaType, !mime.isEmpty {
                        Text(mime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: link.isImage ? "photo" : "link")
            }

            if link.isImage, let url = URL(string: link.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        Text("图片加载失败")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArtifactImageView: View {
    let data: Data

    var body: some View {
        if let image = PlatformImage(data: data) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("无法解码图片")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
import AppKit

private typealias PlatformImage = NSImage

private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#else
import UIKit

private typealias PlatformImage = UIImage

private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#endif
