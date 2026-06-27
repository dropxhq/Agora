import SwiftUI

struct GlassInputBar: View {
    @Binding var text: String
    var placeholder: String = "输入问题..."
    var isSendDisabled: Bool = false
    var onSubmit: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendDisabled
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                MultilineMessageInput(
                    text: $text,
                    placeholder: placeholder,
                    onCommandReturn: onSubmit,
                    canSend: canSend
                )
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                .glassEffect(.regular.interactive(), in: inputShape)

                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .glassEffect(sendGlass, in: .circle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sendGlass: Glass {
        canSend ? .regular.tint(.blue).interactive() : .regular.interactive()
    }
}
