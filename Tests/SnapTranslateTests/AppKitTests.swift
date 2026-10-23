import Testing

/// These suites share NSApplication's focus, event monitors and window list.
/// MainActor isolation alone does not serialize tests across suspension points
/// or AppKit's nested event loops. Pure encoding tests remain parallel.
@Suite(.serialized)
struct AppKitTests {}
