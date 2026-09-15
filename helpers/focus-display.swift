// focus-display — jump the OS's "active display" to the previous/next
// display (v1, compiled Accessibility + IPC helper).
//
// The Lua-side focus_display used to shell out to helpers/mouse-display and
// helpers/display-geometry on every keypress — both ephemeral `swift -e`
// scripts, recompiled from scratch on every invocation, which is the
// dominant cost of the shortcut (commonly 150-400ms). This helper inlines
// the same CoreGraphics enumeration/lookup logic those scripts use, but as
// one precompiled binary (see scripts/install-helpers), so a keypress costs
// one fast process launch instead of a fresh JIT compile.
//
// Usage: focus-display <previous|next>
//
// To find what to focus, this asks the running paneru daemon directly via
// its `query on-screen` CLI (a real IPC round-trip over paneru's socket,
// the same source paneru's own Lua `paneru.query_on_screen()` reads) for
// the on-screen window on the target display, preferring one paneru already
// considers focused. That is the authoritative answer, rather than a
// second-guessed reimplementation of paneru's own window/display bookkeeping.
//
// Once a target point is chosen (a window's frame center, or the target
// display's own center if it has no window), this warps the pointer there.
// `CGWarpMouseCursorPosition` alone does not post a real mouse-moved event
// to any CGEventTap, including paneru's own focus_follows_mouse tap, so
// when a window was found this also posts a synthetic `.mouseMoved` event
// (not a click — nothing on screen should be clicked just to focus it) to
// make that option actually take effect, mirroring the synthesized click
// helpers/move-display.swift posts after its own teleport.
//
// Needs Accessibility access granted to this compiled binary (one-time
// macOS prompt) — posting a synthetic CGEvent is TCC-gated the same way
// AXUIElement calls are, which is also why this is compiled once instead of
// run as an ephemeral `swift -e` script: an ephemeral process gets a fresh,
// effectively anonymous identity every run and could never hold the grant.
import CoreGraphics
import Foundation

struct Display {
  let id: CGDirectDisplayID
  let bounds: CGRect
}

func onlineDisplays() -> [Display] {
  var count: UInt32 = 0
  CGGetOnlineDisplayList(0, nil, &count)
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  CGGetOnlineDisplayList(count, &ids, &count)
  var displays = ids.map { Display(id: $0, bounds: CGDisplayBounds($0)) }
  displays.sort { a, b in
    a.bounds.origin.y != b.bounds.origin.y
      ? a.bounds.origin.y < b.bounds.origin.y
      : a.bounds.origin.x < b.bounds.origin.x
  }
  return displays
}

func currentDisplayIndex(_ displays: [Display]) -> Int {
  guard let event = CGEvent(source: nil) else { return 0 }
  let point = event.location
  return displays.firstIndex { $0.bounds.contains(point) } ?? 0
}

func resolvePaneruBinary() -> String {
  for candidate in ["/opt/homebrew/bin/paneru", "/usr/local/bin/paneru"] {
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return "paneru"
}

// The on-screen window (if any) paneru reports for `displayID`, preferring
// one it already considers focused. Returns nil on any failure (paneru not
// running, bad JSON, no match) rather than throwing — callers fall back to
// warping to the display's own center.
func onScreenWindow(forDisplay displayID: CGDirectDisplayID) -> [String: Any]? {
  let process = Process()
  if #available(macOS 10.13, *) {
    process.executableURL = URL(fileURLWithPath: resolvePaneruBinary())
  } else {
    process.launchPath = resolvePaneruBinary()
  }
  process.arguments = ["query", "on-screen"]
  let stdout = Pipe()
  process.standardOutput = stdout
  process.standardError = Pipe()
  do {
    try process.run()
  } catch {
    return nil
  }
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0,
        let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    return nil
  }
  var best: [String: Any]?
  for window in windows {
    guard let id = window["display_id"] as? Int, CGDirectDisplayID(id) == displayID else { continue }
    if (window["focused"] as? Bool) == true {
      return window
    }
    if best == nil {
      best = window
    }
  }
  return best
}

func center(ofFrame frame: [String: Any]) -> CGPoint? {
  guard let x = frame["x"] as? Double, let y = frame["y"] as? Double,
        let width = frame["width"] as? Double, let height = frame["height"] as? Double else {
    return nil
  }
  return CGPoint(x: x + width / 2, y: y + height / 2)
}

let logPath = NSString(string: "~/.config/mac-scrolling-wm/helpers/display-nav.log").expandingTildeInPath
func log(_ message: String) {
  let formatter = DateFormatter()
  formatter.dateFormat = "[yyyy-MM-dd HH:mm:ss] "
  let line = formatter.string(from: Date()) + message + "\n"
  guard let data = line.data(using: .utf8) else { return }
  if let handle = FileHandle(forWritingAtPath: logPath) {
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
  } else {
    try? data.write(to: URL(fileURLWithPath: logPath))
  }
}

let args = CommandLine.arguments
guard args.count == 2, args[1] == "previous" || args[1] == "next" else {
  FileHandle.standardError.write("usage: focus-display <previous|next>\n".data(using: .utf8)!)
  exit(1)
}
let target = args[1]

let displays = onlineDisplays()
let n = displays.count
guard n >= 2 else {
  log("focus \(target): fewer than 2 displays (\(n))")
  exit(0)
}

let currentIndex = currentDisplayIndex(displays)
let step = target == "previous" ? n - 1 : 1
let targetIndex = ((currentIndex + step) % n + n) % n
let targetDisplay = displays[targetIndex]

log("focus \(target): cur=\(displays[currentIndex].id) idx=\(currentIndex)/\(n) -> target=\(targetDisplay.id)")

if let window = onScreenWindow(forDisplay: targetDisplay.id),
   let frame = window["frame"] as? [String: Any],
   let point = center(ofFrame: frame) {
  CGWarpMouseCursorPosition(point)
  CGAssociateMouseAndMouseCursorPosition(1)
  CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
  log("focus \(target): warped to window \(window["window_id"] ?? -1) on display \(targetDisplay.id)")
} else {
  let point = CGPoint(x: targetDisplay.bounds.midX, y: targetDisplay.bounds.midY)
  CGWarpMouseCursorPosition(point)
  CGAssociateMouseAndMouseCursorPosition(1)
  log("focus \(target): target display \(targetDisplay.id) has no on-screen window, warped to its center")
}
