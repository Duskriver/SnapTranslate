import AppKit
import Carbon.HIToolbox
import Darwin
import CryptoKit

private let multiRealAPI = ProcessInfo.processInfo.environment["SNAP_MULTI_REAL_API"] == "1"
private let multiProbeRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAP_MULTI_PROBE_ROOT"]!)

@MainActor func multiWorkerRecordState(_ count: Int) {
    let data = try! JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "windows": count])
    try! data.write(to: multiProbeRoot.appendingPathComponent("worker-state.json"), options: .atomic)
}

@MainActor func multiWorkerCompleted(_ panel: ResultPanelController) {
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let views = panel.window!.contentView.map(descendants) ?? []
    let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
    let text = views.compactMap { $0 as? NSTextView }.first?.string ?? ""
    let expected = "内存测试。\n敏捷的棕色狐狸跳过懒狗。\n每次翻译后关闭窗口。\n这是公开测试内容。"
    guard labels.contains("翻译完成"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          multiRealAPI || text == expected else { exit(7) }
    let data = try! JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "text_utf8_bytes": text.utf8.count])
    try! data.write(to: multiProbeRoot.appendingPathComponent("complete-\(UUID()).json"), options: .atomic)
}

@MainActor func multiBenchmarkDelegate() -> AppDelegate {
    if multiRealAPI { return AppDelegate() }
    let defaults = UserDefaults(suiteName: "com.local.SnapTranslate.MultiWindowBenchmark")!
    let settings = SettingsStore(defaults: defaults, keyStorage: MultiProbeKeys())
    settings.captureShortcut = KeyboardShortcut(keyCode: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | cmdKey))
    return AppDelegate(settings: settings, capturePermission: { true })
}

@MainActor private func multiWait(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(multiRealAPI ? 180 : 25))
    while try !condition() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "Multi-window probe timed out", code: 1) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor private func completedCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: multiProbeRoot.path).filter { $0.hasPrefix("complete-") }.count
}

@MainActor private func visibleCount() throws -> Int {
    let path = multiProbeRoot.appendingPathComponent("worker-state.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
    return (try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Int])["windows"]!
}

@MainActor private func multiCapture(_ app: AppDelegate) throws -> Task<Void, Never> {
    app.beginCapture()
    let origin = NSScreen.screens[0].frame.origin
    let rect = NSRect(x: origin.x + 110, y: origin.y + 310, width: 870, height: 470)
    guard let panel = NSApp.windows.compactMap({ $0 as? SelectionPanel }).first(where: { $0.isVisible && $0.frame.contains(rect.origin) }) else {
        throw NSError(domain: "Multi-window selection did not open", code: 1)
    }
    let first = NSPoint(x: rect.minX - panel.frame.minX, y: rect.minY - panel.frame.minY)
    let last = NSPoint(x: rect.maxX - panel.frame.minX, y: rect.maxY - panel.frame.minY)
    for (kind, point) in [(NSEvent.EventType.leftMouseDown, first), (.leftMouseDragged, last), (.leftMouseUp, last)] {
        let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
    }
    guard let task = app.translationTask else { throw NSError(domain: "Multi-window task missing", code: 1) }
    return task
}

@MainActor private func multiSample(_ stage: String, windows: Int) async throws {
    guard try visibleCount() == windows else { throw NSError(domain: "Wrong retained window count", code: 1) }
    print("\(stage),\(windows)")
    fflush(stdout)
    try await multiWait {
        (try? String(contentsOf: multiProbeRoot.appendingPathComponent("observer-ack"), encoding: .utf8)) == stage
    }
}

@MainActor func runMultiWindowBenchmark(_ app: AppDelegate) async {
    if multiRealAPI { await runRealAPIMemoryBenchmark(app); return }
    do {
        try await Task.sleep(for: .seconds(1))
        try await multiSample("startup", windows: 0)
        var tasks: [Task<Void, Never>] = []
        var completed = 0
        for n in 1...10 {
            tasks.append(try multiCapture(app))
            completed += 1
            try await multiWait { try completedCount() == completed && visibleCount() == n }
            if [1, 3, 5, 10].contains(n) {
                try await Task.sleep(for: .seconds(1))
                try await multiSample("retained-\(n)", windows: n)
            }
        }
        for remaining in [5, 1, 0] {
            while tasks.count > remaining { let task = tasks.removeLast(); task.cancel(); await task.value }
            try await multiWait { try visibleCount() == remaining }
            try await Task.sleep(for: .seconds(remaining == 0 ? 3 : 1))
            guard app.translationTasks.count == remaining else { throw NSError(domain: "Main task ownership mismatch", code: 1) }
            try await multiSample(remaining == 0 ? "idle-cycle-1" : "closed-to-\(remaining)", windows: remaining)
        }
        for (cycle, count) in [(2, 3), (3, 1)] {
            for n in 1...count {
                tasks.append(try multiCapture(app)); completed += 1
                try await multiWait { try completedCount() == completed && visibleCount() == n }
            }
            try await Task.sleep(for: .seconds(1))
            try await multiSample("reopened-cycle-\(cycle)", windows: count)
            for task in tasks { task.cancel(); await task.value }
            tasks.removeAll()
            try await multiWait { try visibleCount() == 0 && app.translationTasks.isEmpty }
            try await Task.sleep(for: .seconds(3))
            try await multiSample("idle-cycle-\(cycle)", windows: 0)
        }
        try await Task.sleep(for: .milliseconds(300)) // Let the observer collect the final stage.
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        exit(0)
    } catch {
        fputs("MULTI_PROBE_FAILED: \(error.localizedDescription)\n", stderr)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        exit(1)
    }
}

@MainActor private final class MultiProbeKeys: APIKeyStorage {
    func containsKey() throws -> Bool { true }
    func loadKey() throws -> String { "memory-probe-public-placeholder" }
    func saveKey(_ value: String) throws { }
}

/// Benchmark-only control invokes the native title-bar close path in the worker.
@MainActor func multiInstallWorkerControl(_ server: WorkerWindowServer) {
    guard multiRealAPI else { return }
    Task { @MainActor in
        var previousToken = ""
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: multiProbeRoot.appendingPathComponent("worker-control.json")),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               command["pid"] as? Int == Int(getpid()),
               let token = command["token"] as? String, token != previousToken,
               let keep = command["keep"] as? Int, keep >= 0, keep <= server.presentations.count {
                previousToken = token
                let ids = server.presentations.keys.sorted { $0.uuidString < $1.uuidString }
                for id in ids.dropFirst(keep) { server.presentations[id]?.panel.window?.performClose(nil) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Refuse to upload anything other than the byte-identical public test fixture.
@MainActor func multiValidateRealCapture(_ image: CapturedImage) {
    guard multiRealAPI else { return }
    let hash = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
    let record: [String: Any] = ["pid": Int(getpid()), "png_bytes": image.data.count, "sha256": hash]
    let data = try! JSONSerialization.data(withJSONObject: record)
    try! data.write(to: multiProbeRoot.appendingPathComponent("capture-\(UUID()).json"), options: .atomic)
    guard image.data.count == 73207, hash == "60487d35ab1031519dcc7c27736ec31f3fe874eac4f51e9157966cbf48802627" else { exit(8) }
}

@MainActor func multiWorkerFailure(_ error: any Error) {
    let error = error as NSError
    let data = try! JSONSerialization.data(withJSONObject: ["domain": error.domain, "code": error.code])
    try! data.write(to: multiProbeRoot.appendingPathComponent("worker-failure.json"), options: .atomic)
}

@MainActor private func realClose(_ app: AppDelegate, keeping count: Int) async throws {
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: multiProbeRoot.appendingPathComponent("worker-state.json"))) as! [String: Int]
    let command: [String: Any] = ["pid": state["pid"]!, "keep": count, "token": UUID().uuidString]
    try JSONSerialization.data(withJSONObject: command).write(to: multiProbeRoot.appendingPathComponent("worker-control.json"), options: .atomic)
    try await multiWait { try visibleCount() == count && app.translationTasks.count == count }
}

@MainActor private func runRealAPIMemoryBenchmark(_ app: AppDelegate) async {
    do {
        try await Task.sleep(for: .seconds(1))
        try await multiSample("startup", windows: 0)
        var completed = 0
        for n in 1...5 {
            _ = try multiCapture(app)
            completed += 1
            try await multiWait { try completedCount() == completed && visibleCount() == n }
            if [1, 3, 5].contains(n) {
                try await Task.sleep(for: .seconds(2))
                try await multiSample("retained-\(n)", windows: n)
            }
        }
        for remaining in [3, 1] {
            try await realClose(app, keeping: remaining)
            try await Task.sleep(for: .seconds(2))
            try await multiSample("closed-to-\(remaining)", windows: remaining)
        }
        try await realClose(app, keeping: 0)
        for (label, delay) in [(3, 3), (15, 12), (45, 30)] {
            try await Task.sleep(for: .seconds(delay))
            try await multiSample("idle-cycle-1-\(label)s", windows: 0)
        }
        for n in 1...2 {
            _ = try multiCapture(app)
            completed += 1
            try await multiWait { try completedCount() == completed && visibleCount() == n }
        }
        try await Task.sleep(for: .seconds(2))
        try await multiSample("reopened-cycle-2", windows: 2)
        try await realClose(app, keeping: 0)
        for (label, delay) in [(3, 3), (15, 12)] {
            try await Task.sleep(for: .seconds(delay))
            try await multiSample("idle-cycle-2-\(label)s", windows: 0)
        }
        try await Task.sleep(for: .milliseconds(300))
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        exit(0)
    } catch {
        fputs("REAL_API_PROBE_FAILED: \(error.localizedDescription)\n", stderr)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        exit(1)
    }
}
