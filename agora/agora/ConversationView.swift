import SwiftUI

struct ConversationView: View {
    let client: A2AClient
    @State private var vm = ConversationVM()
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !vm.rounds.isEmpty || vm.summary != nil {
                            TurnView(vm: vm)
                                .id("turn")
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.rounds.count) { _, _ in
                    proxy.scrollTo("turn", anchor: .bottom)
                }
            }

            Divider()

            HStack {
                TextField("输入问题...", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("发送", action: submit)
                    .disabled(input.isEmpty || vm.state == .working)
            }
            .padding()
        }
        .navigationTitle("Agora")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
#else
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
#endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        } // NavigationStack
    }

    private func submit() {
        guard !input.isEmpty else { return }
        vm.send(text: input, client: client)
        input = ""
    }
}

struct TurnView: View {
    let vm: ConversationVM
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 进度泳道
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.rounds.indices, id: \.self) { i in
                        RoundView(round: vm.rounds[i], index: i + 1)
                    }
                }
                .padding(.leading, 4)
            } label: {
                Label(
                    vm.state == .working ? "执行中..." : "执行过程",
                    systemImage: vm.state == .working ? "circle.dotted" : "checkmark.circle"
                )
                .foregroundStyle(vm.state == .working ? .orange : .secondary)
            }

            // 总结区（lastChunk 后才出现）
            if let summary = vm.summary {
                Text(summary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            // 错误提示
            if let err = vm.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}

struct RoundView: View {
    let round: Round
    let index: Int
    @State private var resultsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Round \(index)").font(.caption).foregroundStyle(.tertiary)

            if let r = round.reasoning {
                Label(r, systemImage: "bubble.left.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(round.toolCalls) { tc in
                Label("\(tc.name)(\(tc.argsPreview))", systemImage: "wrench.fill")
                    .font(.callout.monospaced())
                    .foregroundStyle(.blue)
            }

            if !round.toolResults.isEmpty {
                DisclosureGroup(isExpanded: $resultsExpanded) {
                    ForEach(round.toolResults) { tr in
                        HStack(alignment: .top) {
                            Image(systemName: tr.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(tr.ok ? .green : .red)
                            Text(tr.result).font(.caption.monospaced())
                        }
                    }
                } label: {
                    Label("工具结果 (\(round.toolResults.count))", systemImage: "tray.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
