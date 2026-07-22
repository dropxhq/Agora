import SwiftUI

struct AgentCardView: View {
    let card: AgentCard
    let backendName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text(card.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            metadataSection

            if let capabilities = card.capabilities, capabilities.hasAny {
                capabilitiesSection(capabilities)
            }

            if let skills = card.skills, !skills.isEmpty {
                skillsSection(skills)
            }

            if card.defaultInputModes != nil || card.defaultOutputModes != nil {
                modesSection
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(card.name)
                    .font(.title3.weight(.semibold))
                Text(backendName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text("v\(card.version)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let protocolVersion = card.protocolVersion {
                metadataRow(label: "协议", value: protocolVersion)
            }
            metadataRow(label: "Endpoint", value: card.url, monospaced: true)
            if let provider = card.provider?.organization {
                metadataRow(label: "Provider", value: provider)
            }
        }
    }

    private func capabilitiesSection(_ capabilities: AgentCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Capabilities")
            AgentCardFlowLayout(spacing: 8) {
                if capabilities.streaming == true {
                    capabilityChip("Streaming", systemImage: "dot.radiowaves.left.and.right")
                }
                if capabilities.pushNotifications == true {
                    capabilityChip("Push", systemImage: "bell.badge")
                }
            }
        }
    }

    private func skillsSection(_ skills: [AgentSkill]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Skills")
            ForEach(skills) { skill in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(skill.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(skill.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(skill.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let tags = skill.tags, !tags.isEmpty {
                        AgentCardFlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    if let examples = skill.examples, !examples.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Examples")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                            ForEach(examples, id: \.self) { example in
                                Text(example)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Modes")
            if let inputModes = card.defaultInputModes, !inputModes.isEmpty {
                metadataRow(label: "Input", value: inputModes.joined(separator: ", "), monospaced: true)
            }
            if let outputModes = card.defaultOutputModes, !outputModes.isEmpty {
                metadataRow(label: "Output", value: outputModes.joined(separator: ", "), monospaced: true)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func metadataRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func capabilityChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.blue.opacity(0.1), in: Capsule())
            .foregroundStyle(.blue)
    }
}

struct AgentCardEmptyStateView: View {
    let backend: Backend
    let store: WorkspaceStore
    var onEditBackend: () -> Void = {}

    var body: some View {
        Group {
            if let card = store.agentCard(for: backend.id) {
                AgentCardView(card: card, backendName: backend.displayTitle)
            } else if store.isLoadingAgentCard(for: backend.id) {
                ProgressView("加载 Agent 信息…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if let error = store.agentCardError(for: backend.id) {
                agentCardErrorView(error)
            } else {
                ProgressView("加载 Agent 信息…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { store.loadAgentCard(for: backend) }
        .onChange(of: backend.serverURL) { _, _ in
            store.invalidateAgentCard(for: backend.id)
            store.loadAgentCard(for: backend)
        }
    }

    private func agentCardErrorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("无法加载 Agent 信息", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") {
                    store.invalidateAgentCard(for: backend.id)
                    store.loadAgentCard(for: backend)
                }
                Button("编辑 Backend", action: onEditBackend)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

private extension AgentCapabilities {
    var hasAny: Bool {
        streaming == true || pushNotifications == true
    }
}

/// Simple horizontal flow layout for tags and capability chips.
private struct AgentCardFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

enum AgentCardErrorMessage {
    static func message(for error: Error, serverURL: String) -> String {
        var lines = ["无法从 \(serverURL) 获取 Agent Card。"]
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                lines.append("无法找到服务器。")
            case .cannotConnectToHost:
                lines.append("无法连接到服务器。")
            case .timedOut:
                lines.append("连接超时。")
            case .badServerResponse, .fileDoesNotExist:
                lines.append("未找到 /.well-known/agent-card.json。")
            default:
                break
            }
        } else if error is DecodingError {
            lines.append("Agent Card JSON 格式与客户端不兼容（缺少 url 或 supportedInterfaces）。")
        }
        lines.append("请确认后端已启动，并在设置中检查 Server URL。")
        return lines.joined(separator: "\n")
    }
}
