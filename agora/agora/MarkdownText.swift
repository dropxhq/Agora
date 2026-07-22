import HTMLToMarkdown
import MarkdownUI
import SwiftUI

enum MarkdownTextStyle {
    /// Result / summary content — primary label color.
    case content
    /// Reasoning / thinking process — secondary label color.
    case process
}

struct MarkdownText: View {
    let content: String
    var style: MarkdownTextStyle = .content

    var body: some View {
        Group {
            switch style {
            case .content:
                Markdown(preparedContent)
                    .markdownTheme(.gitHub)
            case .process:
                // Bake secondary into the theme — MarkdownUI AttributedString
                // ignores parent `.foregroundStyle`, so ambient color alone is not enough.
                Markdown(preparedContent)
                    .markdownTheme(Self.processTheme)
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact secondary-colored theme for reasoning / tool-process copy.
    /// Starts from `.basic` so lists / paragraphs keep working after HTML→Markdown.
    private static let processTheme: Theme = Theme.basic
        .text {
            ForegroundColor(.secondary)
        }
        .code {
            ForegroundColor(.secondary)
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.94))
        }
        .strong {
            ForegroundColor(.secondary)
            FontWeight(.semibold)
        }
        .emphasis {
            ForegroundColor(.secondary)
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.secondary)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: .zero, bottom: .em(0.35))
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: .zero, bottom: .em(0.35))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.1))
        }

    private var preparedContent: String {
        let converted = Self.convertEmbeddedHTMLToMarkdown(in: normalizedContent)
        // HTML→MD often yields `**标签：**值`; CommonMark leaves those `**` literal.
        return Self.fixCommonMarkEmphasisDelimiters(in: converted)
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

    /// When the payload mixes Markdown with raw HTML tags, convert HTML → Markdown
    /// via [html-to-markdown-swift](https://github.com/jaredhowland/html-to-markdown-swift)
    /// before MarkdownUI renders it.
    ///
    /// Fenced / inline code is protected first so placeholders like `<base64>`
    /// inside `` `...` `` are not mistaken for HTML and stripped.
    static func convertEmbeddedHTMLToMarkdown(in text: String) -> String {
        let (protected, tokens) = protectMarkdownCode(text)
        guard containsHTMLTag(protected) else { return text }

        // Wrap so fragment HTML parses as a document; existing Markdown in text
        // nodes is preserved and still rendered by MarkdownUI afterwards.
        let wrapped = "<div>\n\(protected)\n</div>"
        do {
            let converted = try HTMLToMarkdown.convert(
                wrapped,
                plugins: [
                    BasePlugin(),
                    CommonmarkPlugin(),
                    GFMPlugin(),
                ]
            )
            return restoreMarkdownCode(
                converted.trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: tokens
            )
        } catch {
            return text
        }
    }

    /// CommonMark cannot close emphasis when the closing `**`/`__` is both left- and
    /// right-flanking — typical after HTML `<strong>标签：</strong>值` becomes
    /// `**标签：**值`. Move the trailing punctuation outside the delimiters.
    static func fixCommonMarkEmphasisDelimiters(in text: String) -> String {
        let pattern = #"(\*\*|__)(.+?)([:：,，.。;；!！?？、])(\1)(?=\S)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1$2$1$3"
        )
    }

    /// Replace fenced and inline code with opaque placeholders so HTML detection /
    /// conversion cannot touch their contents.
    private static func protectMarkdownCode(_ text: String) -> (String, [String]) {
        var tokens: [String] = []
        var result = text

        // Fenced blocks first (``` or ~~~), then inline `code`.
        let patterns = [
            #"```[\s\S]*?```"#,
            #"~~~[\s\S]*?~~~"#,
            #"`[^`\n]+`"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let matches = regex.matches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            )
            // Replace from the end so earlier ranges stay valid.
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let placeholder = "\u{FFFC}MDCODE\(tokens.count)\u{FFFC}"
                tokens.append(String(result[range]))
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return (result, tokens)
    }

    private static func restoreMarkdownCode(_ text: String, tokens: [String]) -> String {
        var result = text
        for (index, token) in tokens.enumerated() {
            let placeholder = "\u{FFFC}MDCODE\(index)\u{FFFC}"
            result = result.replacingOccurrences(of: placeholder, with: token)
        }
        return result
    }

    /// Only treat real HTML element names as tags — not angle-bracket placeholders
    /// like `<base64>` or generics that may appear outside code spans.
    private static func containsHTMLTag(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"</?([A-Za-z][A-Za-z0-9]*)(?:\s[^>]*)?>"#,
            options: []
        ) else {
            return false
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            if htmlTagNames.contains(text[nameRange].lowercased()) {
                return true
            }
        }
        return false
    }

    private static let htmlTagNames: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "code", "dd", "del", "details",
        "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i",
        "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "s", "samp",
        "section", "small", "span", "strong", "sub", "summary", "sup", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul", "var",
    ]
}
