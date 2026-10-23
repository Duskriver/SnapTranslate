import AppKit

/// These short-lived utility windows do not need the system's zoom/full-screen
/// menu. Keep native closing and edge resizing while removing that entry point.
/// AppKit may still start its view service for system accessibility requests.
@MainActor
enum WindowResourcePolicy {
    static func configureUtilityWindow(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        let zoom = window.standardWindowButton(.zoomButton)
        zoom?.isEnabled = false
        zoom?.isHidden = true
    }
}
