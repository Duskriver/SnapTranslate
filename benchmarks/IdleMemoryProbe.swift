import AppKit
import Darwin

@MainActor func benchmarkMemory(_ stage:String, elapsed:Double = 0) {
 var info = task_vm_info_data_t()
 var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
 let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
 precondition(result == KERN_SUCCESS)
 print("\(stage),\(Double(info.phys_footprint)/1048576),\(Double(info.ledger_phys_footprint_peak)/1048576),\(elapsed)")
 fflush(stdout)
}
@MainActor func benchmarkRound(_ app:AppDelegate) async throws -> Double {
 app.beginCapture()
 let origin = NSScreen.screens[0].frame.origin
 let rect = NSRect(x:origin.x+110,y:origin.y+310,width:870,height:470)
 guard let panel = NSApp.windows.compactMap({$0 as? SelectionPanel}).first(where:{$0.isVisible && $0.frame.contains(rect.origin)}) else { throw NSError(domain:"Benchmark selection did not open",code:1) }
 let first = NSPoint(x:rect.minX-panel.frame.minX,y:rect.minY-panel.frame.minY)
 let last = NSPoint(x:rect.maxX-panel.frame.minX,y:rect.maxY-panel.frame.minY)
 let clock = ContinuousClock()
 let start = clock.now
 for (kind, point) in [(NSEvent.EventType.leftMouseDown,first),(.leftMouseDragged,last),(.leftMouseUp,last)] {
  let event = NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
  panel.sendEvent(event)
 }
 guard let task = app.translationTask else { throw NSError(domain:"Benchmark task did not start",code:1) }
 await task.value
 let elapsed = start.duration(to:clock.now)
 func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
 if let controller = app.resultController {
  guard let view=controller.window?.contentView,
        descendants(view).compactMap({$0 as? NSTextField}).contains(where:{$0.stringValue=="翻译完成"}) else {
   let labels = controller.window?.contentView.map(descendants)?.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ") ?? "no window"
   throw NSError(domain:"Benchmark translation did not complete",code:1,userInfo:[NSLocalizedDescriptionKey:labels])
  }
  controller.window?.performClose(nil)
 }
 return Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15
}
@MainActor func runIdleBenchmark(_ app:AppDelegate) async {
 do {
  try await Task.sleep(for:.seconds(1))
  benchmarkMemory("startup")
  for n in 1...5 {
   let elapsed=try await benchmarkRound(app)
   try await Task.sleep(for:.seconds(3))
   guard app.resultController==nil && app.translationTask==nil else {throw NSError(domain:"Benchmark retained UI/task",code:1)}
   benchmarkMemory("round-\(n)",elapsed:elapsed)
  }
  try await Task.sleep(for:.seconds(5))
  benchmarkMemory("idle-5s")
  app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
  exit(0)
 } catch {
  print("BENCHMARK_FAILED: \(error.localizedDescription)"); fflush(stdout)
  exit(1)
 }
}
@MainActor final class BenchmarkKeys: APIKeyStorage {
 func containsKey() throws -> Bool {true}
 func loadKey() throws -> String {"memory-probe-public-placeholder"}
 func saveKey(_ value:String) throws {}
}
