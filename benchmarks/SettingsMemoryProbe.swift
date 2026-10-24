import AppKit
import Carbon.HIToolbox
import Darwin

private var settingsProbeDirectory: URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAP_SETTINGS_PROBE"]!)
}

@MainActor func settingsBenchmarkDelegate() -> AppDelegate {
    let defaults = UserDefaults(suiteName: "com.local.SnapTranslate.SettingsMemoryProbe")!
    defaults.removePersistentDomain(forName: "com.local.SnapTranslate.SettingsMemoryProbe")
    let store = SettingsStore(defaults: defaults, keyStorage: SettingsProbeKeys())
    store.captureShortcut = KeyboardShortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
    return AppDelegate(settings: store)
}

@MainActor private func recordSettingsMemory(_ stage: String, elapsed: Double = 0) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    print("\(stage),\(Double(info.phys_footprint) / 1048576),\(elapsed)")
    fflush(stdout)
}

@MainActor func runSettingsMemoryBenchmark(_ app: AppDelegate) async {
    do {
        try await Task.sleep(for: .seconds(1))
        recordSettingsMemory("startup")
        try await Task.sleep(for: .milliseconds(200))
        for round in 1...5 {
            let ready = settingsProbeDirectory.appendingPathComponent("ready")
            try? FileManager.default.removeItem(at: ready)
            try String(round).write(to: settingsProbeDirectory.appendingPathComponent("round"), atomically: true, encoding: .utf8)
            let start = ContinuousClock.now
            app.showSettings()
            #if SETTINGS_WORKER
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard FileManager.default.fileExists(atPath: ready.path) else { throw CocoaError(.fileReadUnknown) }
            #endif
            let duration = start.duration(to: .now)
            try await Task.sleep(for: .milliseconds(300))
            recordSettingsMemory("open-\(round)", elapsed: Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            #if !SETTINGS_WORKER
            try await Task.sleep(for: .milliseconds(1200))
            guard let controller = app.settingsController else { throw CocoaError(.coderInvalidValue) }
            try settingsProbeClose(controller, round: round)
            #endif
            let deadlineClosed = ContinuousClock.now.advanced(by: .seconds(10))
            while app.settingsController != nil, ContinuousClock.now < deadlineClosed {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard app.settingsController == nil else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .seconds(1))
            recordSettingsMemory("closed-\(round)")
            // Give the external observer a stable stage before opening the next child.
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(5))
        recordSettingsMemory("idle-5s")
        try await Task.sleep(for: .milliseconds(200))
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        exit(0)
    } catch {
        fputs("Settings benchmark failed: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor private func settingsProbeClose(_ controller: SettingsWindowController, round: Int) throws {
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let views = controller.window!.contentView.map(descendants)!
    if round % 3 == 0 {
        let language = views.compactMap { $0 as? NSPopUpButton }.first!
        language.selectItem(withTitle: "English")
        views.compactMap { $0 as? NSButton }.first { $0.title == "保存" }!.performClick(nil)
    } else if round % 3 == 1 {
        views.compactMap { $0 as? NSButton }.first { $0.title == "取消" }!.performClick(nil)
    } else { controller.window!.performClose(nil) }
}

#if SETTINGS_WORKER
@MainActor func settingsProbeWorker(_ controller: SettingsWindowController) async {
    do {
        let round = Int(try String(contentsOf: settingsProbeDirectory.appendingPathComponent("round"), encoding: .utf8))!
        try Data().write(to: settingsProbeDirectory.appendingPathComponent("ready"))
        try await Task.sleep(for: .milliseconds(1200))
        try settingsProbeClose(controller, round: round)
    } catch { exit(8) }
}
#endif

@MainActor private final class SettingsProbeKeys: APIKeyStorage {
    func containsKey() throws -> Bool { true }
    func loadKey() throws -> String { preconditionFailure("Memory probe must not read a credential") }
    func saveKey(_ value: String) throws { preconditionFailure("Memory probe must not write a credential") }
}
