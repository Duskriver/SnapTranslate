import AppKit
@main struct Fixture {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let origin = NSScreen.screens[0].frame.origin
  let window = NSWindow(contentRect:NSRect(x:origin.x+100,y:origin.y+300,width:900,height:500),styleMask:[.borderless],backing:.buffered,defer:false)
  window.title = "Public translation test fixture"
  window.level = CommandLine.arguments.contains("--floating") ? .floating : NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue-1)
  window.backgroundColor = .white
  let text = NSTextField(wrappingLabelWithString:"Memory test\n\nThe quick brown fox jumps over the lazy dog.\n\nClose the window after each translation.\n\nThis is public test content.")
  text.font = .systemFont(ofSize:26)
  text.textColor = .black
  text.frame = NSRect(x:25,y:25,width:850,height:450)
  window.contentView?.addSubview(text)
  window.orderFrontRegardless()
  withExtendedLifetime(window) { app.run() }
 }
}
