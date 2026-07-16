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
                Image(systemName: file.isImage ? "photo" : "doc")
            }

            if file.isImage, let data = file.imageData {
                ArtifactImageView(data: data)
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
