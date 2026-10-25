import AppKit
import Testing
@testable import SnapTranslate

struct MarkdownRendererTests {
    @Test func headingsAndNestedInlineStylesUseNativeFonts() throws {
        let result = MarkdownRenderer().render("# 标题 👩‍💻\n\n普通 **加粗 *嵌套斜体*** 和 ~~删除~~。")
        #expect(result.string == "标题 👩‍💻\n普通 加粗 嵌套斜体 和 删除。")
        let heading = try font(in: result, at: "标题")
        #expect(heading.pointSize > 15)
        #expect(heading.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try font(in: result, at: "加粗").fontDescriptor.symbolicTraits.contains(.bold))
        let nested = try font(in: result, at: "嵌套斜体")
        #expect(nested.fontDescriptor.symbolicTraits.contains([.bold, .italic]))
        #expect(try font(in: result, at: "普通").pointSize == 15)
        #expect(try attribute(.strikethroughStyle, in: result, at: "删除") as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func allHeadingLevelsHaveDescendingSizesAndDoNotLeakStyles() throws {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n\n") + "\n\nbody"
        let result = MarkdownRenderer().render(source)
        var previousSize: CGFloat = .greatestFiniteMagnitude
        for level in 1...6 {
            let heading = try font(in: result, at: "Heading \(level)")
            #expect(heading.pointSize <= previousSize)
            #expect(heading.fontDescriptor.symbolicTraits.contains(.bold))
            previousSize = heading.pointSize
        }
        #expect(try !font(in: result, at: "body").fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func codeUsesMonospacedFontsAndKeepsLiteralMarkdownAndWhitespace() throws {
        let result = MarkdownRenderer().render("Use `**literal**` here.\n\n```swift\nlet greeting = \"你好 👩‍💻\"\n  **not bold**\n\nprint(greeting)\n```\n\nAfter")
        #expect(result.string == "Use **literal** here.\nlet greeting = \"你好 👩‍💻\"\n  **not bold**\n\nprint(greeting)\nAfter")
        for value in ["**literal**", "let greeting", "**not bold**"] {
            let codeFont = try font(in: result, at: value)
            #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
            #expect(!codeFont.fontDescriptor.symbolicTraits.contains(.bold))
            #expect(try attribute(.backgroundColor, in: result, at: value) is NSColor)
        }
        #expect(try attribute(.backgroundColor, in: result, at: "After") == nil)
    }

    @Test func nestedListsHaveHangingIndentationAndRespectStartingNumber() throws {
        let result = MarkdownRenderer().render("- outer **bold**\n\n  continuation\n\n  7. nested\n  8. next\n- sibling")
        #expect(result.string == "•\touter bold\ncontinuation\n7.\tnested\n8.\tnext\n•\tsibling")
        let outer = try paragraph(in: result, at: "outer")
        let continuation = try paragraph(in: result, at: "continuation")
        let nested = try paragraph(in: result, at: "nested")
        #expect(outer.headIndent > outer.firstLineHeadIndent)
        #expect(continuation.firstLineHeadIndent == outer.headIndent)
        #expect(nested.headIndent > outer.headIndent)
        #expect(nested.firstLineHeadIndent == outer.headIndent)
        #expect(try paragraph(in: result, at: "sibling").headIndent == outer.headIndent)
        #expect(try font(in: result, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func taskListsQuotesAndThematicBreaksRemainReadable() throws {
        let result = MarkdownRenderer().render("> 引用 **重点**\n\n- [x] done\n- [ ] pending\n\n---\n\n正文")
        #expect(result.string == "引用 重点\n• ☑\tdone\n• ☐\tpending\n────────────\n正文")
        #expect(try paragraph(in: result, at: "引用").headIndent > 0)
        #expect(try paragraph(in: result, at: "正文").headIndent == 0)
    }

    @Test func parserHandlesEscapesEntitiesUnclosedFencesAndIndentedCode() throws {
        #expect(MarkdownRenderer().render(#"\*literal\* &amp; &#20013; **bold**"#).string == "*literal* & 中 bold")
        #expect(MarkdownRenderer().render("before **unfinished").string == "before **unfinished")
        let unclosed = MarkdownRenderer().render("```swift\nlet count = 1\n")
        #expect(unclosed.string == "let count = 1")
        #expect(try font(in: unclosed, at: "let").fontDescriptor.symbolicTraits.contains(.monoSpace))
        let indented = MarkdownRenderer().render("    print(\"**literal**\")\n")
        #expect(indented.string == "print(\"**literal**\")")
        #expect(try font(in: indented, at: "print").fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func prosePreservesUnicodeWhitespaceAndPunctuation() {
        let source = " \t\r\ne\u{301} 👩‍💻 🇨🇳 中文 -- \"quoted\"\nnext\n"
        #expect(Array(MarkdownRenderer().render(source).string.utf16) == Array(source.utf16))
        #expect(MarkdownRenderer().render("").length == 0)
        #expect(MarkdownRenderer().render(" \t\n").string == " \t\n")
        #expect(MarkdownRenderer().render("first  \nsecond").string == "first\nsecond")
    }

    @Test func linksImagesAndHTMLStayNative() throws {
        let result = MarkdownRenderer().render("[**网站**](https://example.com) [unsafe](javascript:alert) ![图片说明](https://example.com/image.png) <b>literal</b>")
        #expect(result.string == "网站 unsafe 图片说明 <b>literal</b>")
        #expect(try attribute(.link, in: result, at: "网站") as? URL == URL(string: "https://example.com"))
        #expect(try font(in: result, at: "网站").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try attribute(.link, in: result, at: "unsafe") == nil)
        #expect(try attribute(.attachment, in: result, at: "图片说明") == nil)
        let html = "<script>alert('literal')</script>\n"
        #expect(MarkdownRenderer().render(html).string == html)
    }

    @Test func tableFallbackKeepsCellAndRowBoundaries() throws {
        let result = MarkdownRenderer().render("| 名称 | 值 |\n| --- | --- |\n| **加粗** | `code` |")
        #expect(result.string == "名称  |  值\n加粗  |  code")
        #expect(try font(in: result, at: "名称").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try font(in: result, at: "code").fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func tableFallbackPreservesEmptyCells() {
        let source = "| | Middle | |\n| --- | --- | --- |\n| left | | right |\n| | | |\n| | last | |"
        #expect(MarkdownRenderer().render(source).string == "  |  Middle  |  \nleft  |    |  right\n  |    |  \n  |  last  |  ")
        #expect(MarkdownRenderer().render("| |\n| --- |\n| value |\n| |\n| last |").string == "\nvalue\n\nlast")
        #expect(MarkdownRenderer().render("| Header |\n| --- |").string == "Header")
    }

    private func attribute(_ key: NSAttributedString.Key, in result: NSAttributedString, at substring: String) throws -> Any? {
        let range = (result.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound)
        return result.attribute(key, at: range.location, effectiveRange: nil)
    }

    private func font(in result: NSAttributedString, at substring: String) throws -> NSFont {
        try #require(attribute(.font, in: result, at: substring) as? NSFont)
    }

    private func paragraph(in result: NSAttributedString, at substring: String) throws -> NSParagraphStyle {
        try #require(attribute(.paragraphStyle, in: result, at: substring) as? NSParagraphStyle)
    }
}
