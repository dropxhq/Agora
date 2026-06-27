import SwiftUI

struct MultilineMessageInput: View {
    @Binding var text: String
    var placeholder: String
    var onCommandReturn: () -> Void
    var canSend: Bool

    var body: some View {
#if os(macOS)
        MacMessageTextView(
            text: $text,
            placeholder: placeholder,
            onCommandReturn: onCommandReturn,
            canSend: canSend
        )
#else
        TextField(placeholder, text: $text, axis: .vertical)
            .font(.body)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lineLimit(1...8)
#endif
    }
}

#if os(macOS)
private struct MacMessageTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommandReturn: () -> Void
    var canSend: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCommandReturn: onCommandReturn,
            canSend: canSend
        )
    }

    func makeNSView(context: Context) -> MessageInputContainerView {
        let container = MessageInputContainerView()
        container.textView.delegate = context.coordinator
        container.textView.string = text
        container.placeholderLabel.stringValue = placeholder
        container.onHeightChange = { height in
            context.coordinator.updateHeight(height)
        }
        context.coordinator.textView = container.textView
        context.coordinator.placeholderLabel = container.placeholderLabel
        return container
    }

    func updateNSView(_ container: MessageInputContainerView, context: Context) {
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.canSend = canSend

        if container.textView.string != text {
            container.textView.string = text
            container.refreshHeight()
        }

        container.placeholderLabel.stringValue = placeholder
        container.updatePlaceholderVisibility()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onCommandReturn: () -> Void
        var canSend: Bool
        weak var textView: NSTextView?
        weak var placeholderLabel: NSTextField?

        init(
            text: Binding<String>,
            onCommandReturn: @escaping () -> Void,
            canSend: Bool
        ) {
            _text = text
            self.onCommandReturn = onCommandReturn
            self.canSend = canSend
        }

        func updateHeight(_ height: CGFloat) {
            // Height is driven by the container's intrinsic size.
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            placeholderLabel?.isHidden = !text.isEmpty
            (textView.enclosingScrollView?.superview as? MessageInputContainerView)?.refreshHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let event = NSApp.currentEvent
            if event?.modifierFlags.contains(.command) == true {
                if canSend { onCommandReturn() }
                return true
            }
            return false
        }
    }
}

private final class MessageInputContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let placeholderLabel = NSTextField(labelWithString: "")

    var onHeightChange: ((CGFloat) -> Void)?

    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 22 * 8
    private var cachedHeight: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
    }

    func refreshHeight() {
        guard bounds.width > 0 else { return }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? minHeight
        let next = min(max(used, minHeight), maxHeight)
        if abs(next - cachedHeight) > 0.5 {
            cachedHeight = next
            invalidateIntrinsicContentSize()
            onHeightChange?(cachedHeight)
        }
        updatePlaceholderVisibility()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    override func layout() {
        super.layout()
        refreshHeight()
    }
}
#endif
