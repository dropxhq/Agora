import SwiftUI

struct GlassInputBar: View {
    @Binding var text: String
    var placeholder: String = "输入问题..."
    var isSendDisabled: Bool = false
    var onSubmit: () -> Void

    @State private var inputHeight: CGFloat = MessageInputMetrics.lineHeight

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendDisabled
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            MultilineMessageInput(
                text: $text,
                height: $inputHeight,
                placeholder: placeholder,
                onSubmit: onSubmit,
                canSend: canSend
            )
            .font(.body)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, MessageInputMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassEffect(.regular.interactive(), in: inputShape)
            .onChange(of: text) { _, newValue in
                if newValue.isEmpty { inputHeight = MessageInputMetrics.lineHeight }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
