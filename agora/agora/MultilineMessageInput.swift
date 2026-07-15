import SwiftUI

enum MessageInputMetrics {
    static let lineHeight: CGFloat = 20
    static let verticalPadding: CGFloat = 6
    /// 多行输入上限（行数）
    static let maxLines: CGFloat = 8
}

struct MultilineMessageInput: View {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var canSend: Bool
    var autocompleteActive: Bool = false
    var onAutocompleteNavigate: ((Int) -> Void)? = nil
    var onAutocompleteAccept: (() -> Void)? = nil
    var onAutocompleteDismiss: (() -> Void)? = nil

    var body: some View {
#if os(macOS)
        MacMessageTextView(
            text: $text,
            height: $height,
            placeholder: placeholder,
            onSubmit: onSubmit,
            canSend: canSend,
            autocompleteActive: autocompleteActive,
            onAutocompleteNavigate: onAutocompleteNavigate,
            onAutocompleteAccept: onAutocompleteAccept,
            onAutocompleteDismiss: onAutocompleteDismiss
        )
        .frame(minHeight: height)
        .frame(maxHeight: .infinity)
#else
        TextField(placeholder, text: $text, axis: .vertical)
            .font(.body)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lineLimit(1...8)
            .onKeyPress(.return) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                if autocompleteActive {
                    onAutocompleteAccept?()
                    return .handled
                }
                if canSend { onSubmit() }
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard autocompleteActive else { return .ignored }
                onAutocompleteNavigate?(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard autocompleteActive else { return .ignored }
                onAutocompleteNavigate?(1)
                return .handled
            }
            .onKeyPress(.escape) {
                guard autocompleteActive else { return .ignored }
                onAutocompleteDismiss?()
                return .handled
            }
            .onKeyPress(.tab) {
                guard autocompleteActive else { return .ignored }
                onAutocompleteAccept?()
                return .handled
            }
#endif
    }
}

#if os(macOS)
private struct MacMessageTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var canSend: Bool
    var autocompleteActive: Bool
    var onAutocompleteNavigate: ((Int) -> Void)?
    var onAutocompleteAccept: (() -> Void)?
    var onAutocompleteDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            height: $height,
            onSubmit: onSubmit,
            canSend: canSend
        )
    }

    func makeNSView(context: Context) -> MessageInputContainerView {
        let container = MessageInputContainerView()
        container.textView.delegate = context.coordinator
        container.textView.string = text
        container.placeholderLabel.stringValue = placeholder
        container.onHeightChange = { [weak coordinator = context.coordinator] newHeight in
            coordinator?.updateHeight(newHeight)
        }
        context.coordinator.textView = container.textView
        context.coordinator.placeholderLabel = container.placeholderLabel
        context.coordinator.containerView = container
        DispatchQueue.main.async {
            container.refreshHeight()
        }
        return container
    }

    func updateNSView(_ container: MessageInputContainerView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.canSend = canSend
        context.coordinator.autocompleteActive = autocompleteActive
        context.coordinator.onAutocompleteNavigate = onAutocompleteNavigate
        context.coordinator.onAutocompleteAccept = onAutocompleteAccept
        context.coordinator.onAutocompleteDismiss = onAutocompleteDismiss

        if container.textView.string != text {
            container.textView.string = text
            container.refreshHeight()
        }

        container.placeholderLabel.stringValue = placeholder
        container.updatePlaceholderVisibility()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        var onSubmit: () -> Void
        var canSend: Bool
        var autocompleteActive = false
        var onAutocompleteNavigate: ((Int) -> Void)?
        var onAutocompleteAccept: (() -> Void)?
        var onAutocompleteDismiss: (() -> Void)?
        weak var textView: NSTextView?
        weak var placeholderLabel: NSTextField?
        weak var containerView: MessageInputContainerView?

        init(
            text: Binding<String>,
            height: Binding<CGFloat>,
            onSubmit: @escaping () -> Void,
            canSend: Bool
        ) {
            _text = text
            _height = height
            self.onSubmit = onSubmit
            self.canSend = canSend
        }

        func updateHeight(_ newHeight: CGFloat) {
            guard abs(height - newHeight) > 0.5 else { return }
            height = newHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            placeholderLabel?.isHidden = !text.isEmpty
            scheduleHeightRefresh()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if autocompleteActive {
                switch commandSelector {
                case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
                    onAutocompleteNavigate?(-1)
                    return true
                case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
                    onAutocompleteNavigate?(1)
                    return true
                case #selector(NSStandardKeyBindingResponding.insertTab(_:)):
                    onAutocompleteAccept?()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    onAutocompleteDismiss?()
                    return true
                default:
                    break
                }
            }

            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let event = NSApp.currentEvent
            if event?.modifierFlags.contains(.shift) == true {
                scheduleHeightRefresh()
                return false
            }
            if autocompleteActive {
                onAutocompleteAccept?()
                return true
            }
            if canSend { onSubmit() }
            return true
        }

        private func scheduleHeightRefresh() {
            DispatchQueue.main.async { [weak containerView] in
                containerView?.refreshHeight()
            }
        }
    }
}

private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MessageInputContainerView: NSView {
    let textView = NSTextView()
    let placeholderLabel = PlaceholderLabel(labelWithString: "")

    var onHeightChange: ((CGFloat) -> Void)?

    private var cachedHeight: CGFloat = MessageInputMetrics.lineHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    private func configure() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func refreshHeight() {
        guard bounds.width > 0 else { return }
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }

        textView.textContainer?.containerSize = NSSize(
            width: bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        manager.ensureLayout(for: container)

        var layoutLineCount = 0
        let glyphRange = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            layoutLineCount += 1
        }

        let explicitLineCount = max(1, textView.string.components(separatedBy: "\n").count)
        let lineCount = max(max(layoutLineCount, 1), explicitLineCount)

        let lineHeight = MessageInputMetrics.lineHeight
        let next = min(CGFloat(lineCount) * lineHeight, lineHeight * MessageInputMetrics.maxLines)

        if abs(next - cachedHeight) > 0.5 {
            cachedHeight = next
            onHeightChange?(next)
        }

        updateVerticalTextInset()
        updatePlaceholderVisibility()
    }

    /// 单行时在可用高度内垂直居中文字与占位符，多行时顶对齐。
    private func updateVerticalTextInset() {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        manager.ensureLayout(for: container)
        let usedHeight = max(manager.usedRect(for: container).height, 1)
        let hasNewline = textView.string.contains(where: \.isNewline)
        let isSingleVisualLine = !hasNewline && usedHeight <= MessageInputMetrics.lineHeight * 1.4

        if isSingleVisualLine, bounds.height > usedHeight + 1 {
            let inset = max(0, (bounds.height - usedHeight) / 2)
            textView.textContainerInset = NSSize(width: 0, height: inset)
        } else {
            textView.textContainerInset = .zero
        }
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
