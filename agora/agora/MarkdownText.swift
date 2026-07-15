import MarkdownUI
import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        Markdown(normalizedContent)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var normalizedContent: String {
        var text = content
        if !text.contains("\n"), text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
