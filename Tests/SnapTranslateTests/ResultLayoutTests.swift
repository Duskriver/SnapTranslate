import AppKit
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    struct ResultLayoutTests {
        @Test(arguments: [NSScroller.Style.overlay, .legacy])
        func translationWrapsWithinViewportWhileStreamingAndResizing(style: NSScroller.Style) throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            scroll.scrollerStyle = style
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let container = try #require(text.textContainer)
            // Reading layoutManager would switch to TextKit 1 and change the
            // production layout path this regression test is meant to exercise.
            let layout = try #require(text.textLayoutManager)
            let paragraph = "这是一段用于检查译文自动换行的中文内容，混合 English words、代码 profileBundle 和 emoji 👩‍💻。"
                + "https://example.invalid/" + String(repeating: "long_identifier_", count: 50) + "\n"
            var expected = ""

            for width: CGFloat in [440, 584, 340, 900, 440] {
                window.setContentSize(NSSize(width: width, height: 354))
                content.layoutSubtreeIfNeeded()
                for fragment in [paragraph, paragraph] {
                    controller.append(delta: fragment)
                    expected += fragment
                    layout.ensureLayout(for: layout.documentRange)
                    #expect(text.string == expected)
                    #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
                    #expect(abs(scroll.contentView.bounds.minX) < 1)
                    #expect(abs(container.containerSize.width - (scroll.contentSize.width - 2 * text.textContainerInset.width)) < 1)
                    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                        for line in fragment.textLineFragments {
                            let bounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + text.textContainerOrigin.x, dy: 0)
                            #expect(bounds.minX >= 0)
                            #expect(bounds.maxX <= scroll.contentSize.width + 1)
                        }
                        return true
                    }
                }
            }
            controller.finish()
            #expect(text.string == expected)
        }

        @Test func tilingRepairsAnOversizedDocumentAndHorizontalOffset() throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            controller.append(delta: String(repeating: "译文应完整显示，缩放窗口时自动换行。\n", count: 30))
            text.setSelectedRange(NSRange(location: 2, length: 4))
            // Reproduce the mismatched geometry: a document wider than its
            // viewport, with content scrolled sideways despite no scroller.
            text.setFrameSize(NSSize(width: scroll.contentSize.width + 300, height: text.frame.height))
            scroll.contentView.scroll(to: NSPoint(x: 150, y: 40))
            try #require(scroll.contentView.bounds.minX > 0)
            scroll.tile()
            #expect(text.frame.width == scroll.contentSize.width)
            #expect(scroll.contentView.bounds.minX == 0)
            #expect(text.selectedRange() == NSRange(location: 2, length: 4))
        }

        @Test func renderedMarkdownWrapsWithinViewportOnResize() throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let layout = try #require(text.textLayoutManager)
            let longLine = String(repeating: "long_identifier_", count: 40)
            controller.append(delta: "# 标题\n\n- **加粗** " + longLine + "\n  - 嵌套列表内容\n\n```swift\n" + longLine + "\n```")
            controller.finish()
            for width: CGFloat in [340, 584, 440] {
                window.setContentSize(NSSize(width: width, height: 354))
                content.layoutSubtreeIfNeeded()
                layout.ensureLayout(for: layout.documentRange)
                #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
                #expect(abs(scroll.contentView.bounds.minX) < 1)
                layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                    for line in fragment.textLineFragments {
                        let bounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + text.textContainerOrigin.x, dy: 0)
                        #expect(bounds.minX >= 0)
                        #expect(bounds.maxX <= scroll.contentSize.width + 1)
                    }
                    return true
                }
            }
        }

        private func makeController() throws -> (ResultPanelController, NSScrollView, NSTextView) {
            _ = NSApplication.shared
            let controller = ResultPanelController()
            controller.window?.alphaValue = 0
            controller.showLoading()
            let content = try #require(controller.window?.contentView)
            let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
            return (controller, scroll, try #require(scroll.documentView as? NSTextView))
        }
    }
}
