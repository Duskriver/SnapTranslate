import AppKit
import Testing
import TranslationCore
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    @Suite(.serialized)
    struct IncrementalResultTests {
        @Test func splitUnicodeAndWhitespaceAppendExactlyOnce() throws {
            let (controller, text, controls) = try makeController()
            defer { controller.dismiss() }
            let copy = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "复制译文" })
            let fragments = [" \t", "\r", "\n", "e", "\u{301}", "👩", "\u{200D}", "💻", "🇨", "🇳", "中文", "\n"]
            var expected = ""
            for fragment in fragments {
                controller.append(delta: fragment)
                expected.append(fragment)
                #expect(Array(text.string.utf16) == Array(expected.utf16))
                #expect(copy.isEnabled == !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            controller.finish()
            controller.append(delta: "")
            #expect(text.string == expected)
            #expect(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "翻译完成" })
            controller.dismiss()
            controller.append(delta: "late")
            #expect(text.string.isEmpty)
            controller.showLoading()
            controller.append(delta: "fresh")
            controller.finish()
            #expect(text.string == "fresh")
        }

        @Test func emptyAndFailedPresentationsDoNotBecomeTranslationText() throws {
            let (controller, text, _) = try makeController()
            defer { controller.dismiss() }
            controller.append(delta: " \r\n")
            controller.finish()
            #expect(text.string == TranslationError.emptyTranslation.localizedDescription)
            controller.append(delta: "first")
            #expect(text.string == "first")
            controller.showError(TranslationError.incompleteStream)
            controller.append(delta: "")
            controller.finish()
            #expect(text.string == "first")
            controller.append(delta: " second")
            controller.finish()
            #expect(text.string == "first second")
        }

        @Test func appendingPreservesSelectionAndUserScrollPosition() throws {
            let (controller, text, controls) = try makeController()
            defer { controller.dismiss() }
            let scroll = try #require(controls.compactMap { $0 as? NSScrollView }.first)
            controller.append(delta: String(repeating: "已经显示的文字与代码 let count = 42;\n", count: 120))
            let container = try #require(text.textContainer)
            text.layoutManager?.ensureLayout(for: container)
            text.setSelectedRange(NSRange(location: 3, length: 5))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let origin = scroll.contentView.bounds.origin
            try #require(scroll.contentView.bounds.maxY < text.bounds.height - 40)
            controller.append(delta: "new content\n")
            text.layoutManager?.ensureLayout(for: container)
            #expect(text.selectedRange() == NSRange(location: 3, length: 5))
            #expect(scroll.contentView.bounds.origin == origin)
        }

        private func makeController() throws -> (ResultPanelController, NSTextView, [NSView]) {
            _ = NSApplication.shared
            let controller = ResultPanelController()
            controller.window?.alphaValue = 0
            controller.showLoading()
            let content = try #require(controller.window?.contentView)
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let controls = descendants(content)
            return (controller, try #require(controls.compactMap { $0 as? NSTextView }.first), controls)
        }
    }
}
