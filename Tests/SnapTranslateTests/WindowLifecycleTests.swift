import AppKit
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    @Suite(.serialized)
    struct WindowLifecycleTests {
        @Test func utilityWindowsKeepCloseAndResultResizeWithoutZoomMenu() throws {
            _ = NSApplication.shared
            let settings = SettingsWindowController(store: SettingsStore(), hotKey: GlobalHotKey())
            let result = ResultPanelController()
            defer { settings.close(); result.close() }
            for window in [try #require(settings.window), try #require(result.window)] {
                #expect(window.standardWindowButton(.zoomButton)?.isHidden != false)
                #expect(window.standardWindowButton(.zoomButton)?.isEnabled != true)
                #expect(window.standardWindowButton(.closeButton)?.isEnabled == true)
                #expect(window.tabbingMode == .disallowed)
                #expect(window.collectionBehavior.contains(.fullScreenDisallowsTiling))
            }
            let panel = try #require(result.window)
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(panel.styleMask.contains(.resizable))
            let frame = panel.frame.insetBy(dx: -20, dy: -20)
            panel.setFrame(frame, display: false)
            #expect(panel.frame == frame)
        }

        @Test(arguments: ["dismiss", "escape", "titleBar"])
        func repeatedResultWindowsReleaseContentAndCancelWork(route: String) async throws {
            _ = NSApplication.shared
            var released: [WeakResource] = []
            for _ in 0..<10 {
                try autoreleasepool {
                    var owner: ResultPanelController? = ResultPanelController()
                    let controller = try #require(owner)
                    let window = try #require(controller.window)
                    let content = try #require(window.contentView)
                    released += [WeakResource(controller), WeakResource(window), WeakResource(content)]
                    window.alphaValue = 0
                    let work = Task { try? await Task.sleep(for: .seconds(60)) }
                    defer { work.cancel() }
                    var closes = 0
                    controller.onClose = {
                        closes += 1
                        work.cancel()
                        owner = nil
                    }
                    controller.showLoading()
                    controller.append(delta: "Synthetic translation for lifecycle regression.")
                    switch route {
                    case "escape": window.cancelOperation(nil)
                    case "titleBar": window.performClose(nil)
                    default: controller.dismiss()
                    }
                    controller.dismiss()
                    #expect(closes == 1)
                    #expect(owner == nil)
                    #expect(work.isCancelled)
                    #expect(!window.isVisible)
                    let controls = descendants(of: content)
                    #expect(controls.compactMap { $0 as? NSTextView }.allSatisfy { $0.string.isEmpty })
                    #expect(controls.compactMap { $0 as? NSProgressIndicator }.allSatisfy { $0.isHidden })
                }
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(released.allSatisfy { $0.value == nil })
        }

        @Test func repeatedSelectionCancellationReleasesPanelsAndCallbacks() async throws {
            _ = NSApplication.shared
            let selector = RegionSelector()
            var released: [WeakResource] = []
            var cancellations = 0
            for index in 0..<20 {
                autoreleasepool {
                    let captured = NSObject()
                    released.append(WeakResource(captured))
                    selector.begin { [captured] region in
                        withExtendedLifetime(captured) {
                            #expect(region == nil)
                            cancellations += 1
                        }
                    }
                    for window in NSApp.windows where window is SelectionPanel {
                        window.alphaValue = 0
                        released.append(WeakResource(window))
                        if let content = window.contentView { released.append(WeakResource(content)) }
                    }
                    if index.isMultiple(of: 2) {
                        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                    } else {
                        selector.cancel()
                    }
                    selector.cancel()
                    #expect(!selector.isSelecting)
                    #expect(cancellations == index + 1)
                }
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(released.allSatisfy { $0.value == nil })
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(cancellations == 20)
        }

        private func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
    }
}

@MainActor
private final class WeakResource {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
