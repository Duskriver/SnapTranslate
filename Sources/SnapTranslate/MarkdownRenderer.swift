import AppKit
import Markdown

/// Converts Markdown's parsed tree directly into native text attributes.
/// No HTML importer, web view, remote images, or syntax matching is involved.
struct MarkdownRenderer {
    static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    func render(_ source: String) -> NSAttributedString {
        var visitor = AttributedStringVisitor()
        // Translation punctuation and code-like text must not be smartened.
        let result = visitor.visit(Document(parsing: source, options: [.disableSmartOpts]))
        // Keep boundary whitespace verbatim for ordinary streamed prose. Escapes
        // and entities still use the parser's decoded text, even without styling.
        if !visitor.hasFormatting,
           result.string.trimmingCharacters(in: .whitespacesAndNewlines)
            == source.trimmingCharacters(in: .whitespacesAndNewlines) {
            return NSAttributedString(string: source, attributes: Self.textAttributes)
        }
        return result
    }
}

private struct AttributedStringVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    private var font = NSFont.systemFont(ofSize: 15)
    private var indent: CGFloat = 0
    private var color = NSColor.textColor
    private(set) var hasFormatting = false

    private var paragraphStyle: NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        if indent > 0 {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }
        return paragraph
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
    }

    private func text(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: attributes)
    }

    private mutating func children(of markup: any Markup, separator: String = "", preservingEmptyChildren: Bool = false) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        var hasPreviousChild = false
        for child in markup.children {
            let rendered = visit(child)
            guard preservingEmptyChildren || rendered.length > 0 else { continue }
            if hasPreviousChild, !separator.isEmpty {
                // Give the separator the preceding block's paragraph style.
                let style = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil) : attributes
                result.append(NSAttributedString(string: separator, attributes: style))
            }
            result.append(rendered)
            hasPreviousChild = true
        }
        return result
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        children(of: markup, separator: markup is any BlockMarkup ? "\n" : "")
    }

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        // Paragraph styles supply vertical spacing without empty text lines.
        children(of: document, separator: "\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        children(of: paragraph)
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString { self.text(text.string) }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString { text("\n") }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString { text("\n") }

    private mutating func styledChildren(_ markup: any Markup, trait: NSFontDescriptor.SymbolicTraits) -> NSAttributedString {
        hasFormatting = true
        let previous = font
        font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
        defer { font = previous }
        return children(of: markup)
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        styledChildren(strong, trait: .bold)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        styledChildren(emphasis, trait: .italic)
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        hasFormatting = true
        let previous = font
        let sizes: [CGFloat] = [26, 23, 20, 18, 16, 15]
        font = .systemFont(ofSize: sizes[min(max(heading.level, 1), 6) - 1], weight: .bold)
        defer { font = previous }
        let result = children(of: heading)
        let paragraph = paragraphStyle
        paragraph.paragraphSpacingBefore = 8
        paragraph.paragraphSpacing = 10
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        hasFormatting = true
        var style = attributes
        let mono = NSFont.monospacedSystemFont(ofSize: max(12, font.pointSize - 1), weight: .regular)
        let traits = mono.fontDescriptor.symbolicTraits.union(font.fontDescriptor.symbolicTraits)
        style[.font] = NSFont(descriptor: mono.fontDescriptor.withSymbolicTraits(traits), size: mono.pointSize) ?? mono
        style[.backgroundColor] = NSColor.quaternaryLabelColor
        return NSAttributedString(string: inlineCode.code, attributes: style)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        hasFormatting = true
        var style = attributes
        style[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        style[.backgroundColor] = NSColor.quaternaryLabelColor
        let paragraph = paragraphStyle
        paragraph.firstLineHeadIndent = indent + 10
        paragraph.headIndent = indent + 10
        paragraph.tailIndent = -10
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        style[.paragraphStyle] = paragraph
        // cmark terminates code blocks with a newline; block separators supply it.
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        return NSAttributedString(string: code, attributes: style)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> NSAttributedString {
        renderList(orderedList, start: orderedList.startIndex)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> NSAttributedString {
        renderList(unorderedList, start: nil)
    }

    private mutating func renderList(_ list: any Markup, start: UInt?) -> NSAttributedString {
        hasFormatting = true
        let previous = indent
        let items = list.children.compactMap { $0 as? ListItem }
        let markers = items.enumerated().map { offset, item in
            let marker = start.map { "\($0 + UInt(offset))." } ?? "•"
            switch item.checkbox {
            case .checked: return "\(marker) ☑"
            case .unchecked: return "\(marker) ☐"
            case nil: return marker
            }
        }
        let markerWidth = markers.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        indent += max(24, ceil(markerWidth) + 10)
        defer { indent = previous }
        let result = NSMutableAttributedString(string: "")
        for (item, marker) in zip(items, markers) {
            if result.length > 0 { result.append(text("\n")) }
            let content = children(of: item, separator: "\n")
            let prefix = NSMutableAttributedString(attributedString: text(marker + "\t"))
            prefix.append(content)
            // Only the first paragraph carries a marker. Continuation blocks
            // and nested lists keep the indentation assigned by their visitor.
            let firstParagraph = (prefix.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            let paragraph = paragraphStyle
            paragraph.firstLineHeadIndent = previous
            prefix.addAttribute(.paragraphStyle, value: paragraph, range: firstParagraph)
            result.append(prefix)
        }
        return result
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        hasFormatting = true
        let previousIndent = indent
        let previousColor = color
        indent += 16
        color = .secondaryLabelColor
        defer { indent = previousIndent; color = previousColor }
        return children(of: blockQuote, separator: "\n")
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        hasFormatting = true
        let result = children(of: link)
        if let destination = link.destination, let url = URL(string: destination),
           let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
            let range = NSRange(location: 0, length: result.length)
            result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        hasFormatting = true
        let result = children(of: strikethrough)
        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: result.length))
        return result
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        hasFormatting = true
        return text("────────────")
    }

    // Images display their alternative text; HTML remains literal selectable
    // text. Neither path fetches resources or interprets executable markup.
    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        hasFormatting = true
        return children(of: image)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString { text(inlineHTML.rawHTML) }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> NSAttributedString { text(html.rawHTML) }

    // Native text fallback for GFM tables, with readable cell/row boundaries.
    mutating func visitTable(_ table: Table) -> NSAttributedString {
        hasFormatting = true
        let result = NSMutableAttributedString(attributedString: visit(table.head))
        if table.body.childCount > 0 {
            result.append(text("\n"))
            result.append(visit(table.body))
        }
        return result
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> NSAttributedString {
        let previous = font
        font = .boldSystemFont(ofSize: font.pointSize)
        defer { font = previous }
        return children(of: tableHead, separator: "  |  ", preservingEmptyChildren: true)
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> NSAttributedString {
        children(of: tableBody, separator: "\n", preservingEmptyChildren: true)
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> NSAttributedString {
        children(of: tableRow, separator: "  |  ", preservingEmptyChildren: true)
    }
}
