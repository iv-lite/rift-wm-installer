// move-display — teleport a window onto another display (v9).
//
// Paneru can only move a window to a single fixed display ("other().next()"
// in its ECS), which cannot reach every monitor on a 3+ display setup, and
// there is no "move to display N" primitive anywhere in paneru's protocol —
// checked the full Command/Operation/MouseMove vocabulary and the CLI argv
// grammar in the real paneru source (crates/shared_types/src/commands.rs,
// crates/shared_types/src/argv.rs): "nextdisplay"/"nextdisplaysend" are the
// only display-move tokens, both zero-argument. For 3+ display setups this
// helper does the physical relocation itself. It is invoked by
// config/paneru/lib/displays.lua (Cmd+Ctrl+Shift+arrows) and must be
// installed (compiled) at $HOME/.config/mac-scrolling-wm/helpers/move-display.
//
// What this helper actually does:
//   1. Teleport via AX   (AXUIElement set-position + verify landing)
//   2. Click to rotate   (synthetic click on target display, so paneru's
//                         focus_follows_mouse tap picks up the new display)
//   3. Send `window fullwidth` (unconditionally, regardless of the window's
//      prior tiled/floating state)
//
// Known limitation: unlike `nextdisplay` (a real paneru ECS operation used
// for the 2-display case in lib/displays.lua), this AX-teleport is invisible
// to paneru's strip/row membership tracking — the window is only physically
// repositioned, never removed from its old row or added to a new one in the
// daemon's model. That means the source workspace's viewport does not
// auto-correct/recenter when the window leaves it, the way it does on paths
// where row membership actually changes. `findWindowState`/`pollWindow`
// below and `wasFloating` (parsed from argv but otherwise unused) are
// leftovers from an earlier float/re-tile design that was never wired up;
// closing this gap for real needs either that toggle or a native
// "move window to display N" daemon command, neither of which this helper
// currently does.
//
// Why CLI round-trips instead of Lua paneru.run: paneru batches all
// `paneru.run`/`ws:focus` commands in a Lua-side outbox that is only flushed
// to the ECS *after the keybind dispatch returns* (worker.rs Task::finish).
// So any in-dispatch poll of `paneru.query_json("state")` can never observe
// the effect of a `paneru.run` within the same dispatch — the poll always
// reads pre-command state and times out. CLI commands, by contrast, are
// separate Mach port messages that the daemon processes independently; by the
// time the next CLI invocation (query) arrives, the previous command has
// been applied. A short poll with retries covers the edge case where the
// daemon's frame hasn't run yet.
//
// Usage: move-display <window_id> <x> <y> <width> <height> <was_floating>
// <window_id> is the exact CGWindowID Lua wants moved.
// <x> <y> <width> <height> is the target display's frame in CG coordinates.
// <was_floating> is "0" (tiled — helper floats, teleports, re-tiles) or
// "1" (already floating — helper only teleports; Lua leaves it floating).
//
// Exit 0 = success. Nonzero = failure (stderr has diagnostics).
//
// Needs Accessibility access granted to this specific compiled binary (a
// one-time macOS prompt) — see scripts/install-helpers for why this is built
// once with swiftc instead of run as an ephemeral `swift -e` script like the
// other helpers: an ephemeral script gets a fresh, effectively anonymous
// identity on every run, which never keeps a TCC grant across invocations.
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

let args = CommandLine.arguments
guard args.count == 7, let windowIDArg = Int(args[1]),
      let windowID = UInt32(args[1]),
      let tx = Double(args[2]), let ty = Double(args[3]),
      let tw = Double(args[4]), let th = Double(args[5]),
      (args[6] == "0" || args[6] == "1") else {
  FileHandle.standardError.write(
    "usage: move-display <window_id> <x> <y> <width> <height> <was_floating(0|1)>\n"
      .data(using: .utf8)!)
  exit(1)
}
let wasFloating = args[6] == "1"

// ─── paneru CLI helpers ───────────────────────────────────────────────────

func resolvePaneruBinary() -> String {
  for candidate in ["/opt/homebrew/bin/paneru", "/usr/local/bin/paneru"] {
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return "paneru"
}

let PANERU = resolvePaneruBinary()

func runPaneruCLI(_ argv: [String]) -> (code: Int32, stdout: String, stderr: String) {
  let process = Process()
  if #available(macOS 10.13, *) {
    process.executableURL = URL(fileURLWithPath: PANERU)
  } else {
    process.launchPath = PANERU
  }
  process.arguments = argv
  let outPipe = Pipe(), errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe
  do {
    try process.run()
  } catch {
    return (-1, "", "failed to run paneru: \(error.localizedDescription)")
  }
  process.waitUntilExit()
  let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  return (process.terminationStatus, out, err)
}

func findWindowState(_ wid: Int) -> [String: Any]? {
  let (_, stdout, _) = runPaneruCLI(["query", "state"])
  guard let data = stdout.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let workspaces = json["virtual_workspaces"] as? [[String: Any]] else {
    return nil
  }
  for ws in workspaces {
    guard let windows = ws["windows"] as? [[String: Any]] else { continue }
    if let match = windows.first(where: { ($0["window_id"] as? Int) == wid }) {
      return match
    }
  }
  return nil
}

/// Poll `paneru query state` until `predicate(w)` holds, or exhaust retries.
func pollWindow(_ wid: Int, retries: Int = 10, delay: TimeInterval = 0.05,
                _ predicate: @escaping ([String: Any]) -> Bool) -> Bool {
  for _ in 0..<retries {
    if let w = findWindowState(wid), predicate(w) { return true }
    Thread.sleep(forTimeInterval: delay)
  }
  return false
}

// ─── Resolve the AX window element ────────────────────────────────────────

func ownerPID(ofWindow wid: CGWindowID) -> pid_t? {
  guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]],
        let info = list.first,
        let pid = info[kCGWindowOwnerPID as String] as? Int else {
    return nil
  }
  return pid_t(pid)
}

guard let pid = ownerPID(ofWindow: windowID) else {
  FileHandle.standardError.write("window \(windowID) not found\n".data(using: .utf8)!)
  exit(1)
}

// Some apps only permit repositioning their windows via Accessibility while
// the app itself is active.
if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
  app.activate(options: [])
  Thread.sleep(forTimeInterval: 0.15)
}

let appElement = AXUIElementCreateApplication(pid)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let axWindows = windowsRef as? [AXUIElement] else {
  FileHandle.standardError.write("could not list windows for pid \(pid)\n".data(using: .utf8)!)
  exit(1)
}
var matchedWindow: AXUIElement?
for candidate in axWindows {
  var candidateID: CGWindowID = 0
  if _AXUIElementGetWindow(candidate, &candidateID) == .success, candidateID == windowID {
    matchedWindow = candidate
    break
  }
}
guard let window = matchedWindow else {
  FileHandle.standardError.write("window \(windowID) not found among pid \(pid)'s AX windows\n"
    .data(using: .utf8)!)
  exit(1)
}

func readFrame(_ window: AXUIElement) -> (position: CGPoint, size: CGSize) {
  var positionRef: CFTypeRef?
  var sizeRef: CFTypeRef?
  AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
  var position = CGPoint.zero
  var size = CGSize.zero
  if let positionRef { _ = AXValueGetValue((positionRef as! AXValue), .cgPoint, &position) }
  if let sizeRef { _ = AXValueGetValue((sizeRef as! AXValue), .cgSize, &size) }
  return (position, size)
}

func center(of frame: (position: CGPoint, size: CGSize)) -> CGPoint {
  CGPoint(x: frame.position.x + frame.size.width / 2,
          y: frame.position.y + frame.size.height / 2)
}

func isOnTarget(_ point: CGPoint) -> Bool {
  point.x >= tx && point.x < tx + tw && point.y >= ty && point.y < ty + th
}

var landedFrame = readFrame(window)
var landed = false
for attempt in 1...10 {
  var targetPoint = CGPoint(x: tx, y: ty)
  guard let positionValue = AXValueCreate(.cgPoint, &targetPoint) else { exit(1) }
  let setResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
  guard setResult == .success else {
    FileHandle.standardError.write("set position failed (attempt \(attempt)): \(setResult.rawValue)\n"
      .data(using: .utf8)!)
    exit(1)
  }
  landedFrame = readFrame(window)
  if isOnTarget(center(of: landedFrame)) {
    landed = true
    break
  }
  Thread.sleep(forTimeInterval: 0.02)
}
guard landed else {
  let c = center(of: landedFrame)
  FileHandle.standardError.write(
    "window \(windowID) did not land on target display: center (\(c.x), \(c.y)) not within [\(tx), \(tx + tw)) x [\(ty), \(ty + th))\n"
      .data(using: .utf8)!)
  exit(1)
}

// ─── Click to rotate active display ───────────────────────────────────────

let finalCenter = center(of: landedFrame)
CGWarpMouseCursorPosition(finalCenter)
CGAssociateMouseAndMouseCursorPosition(1)
// Modifier flags default to whatever is *physically* held right now — and
// since this fires mid-dispatch of the Cmd+Ctrl+Shift+arrow keybind, Ctrl is
// still down. Left-clicking with Ctrl held is macOS's global secondary-click
// gesture, which turned this synthetic click into a right-click and popped a
// context menu on the target display. Zeroing .flags strips that before post.
let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: finalCenter, mouseButton: .left)
mouseDown?.flags = []
mouseDown?.post(tap: .cghidEventTap)
let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: finalCenter, mouseButton: .left)
mouseUp?.flags = []
mouseUp?.post(tap: .cghidEventTap)

_ = runPaneruCLI(["send-cmd", "window", "fullwidth"])