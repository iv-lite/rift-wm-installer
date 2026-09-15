// move-display — teleport the focused window onto another display (v6, native
// Accessibility).
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
// This helper does exactly one thing: use the Accessibility API (AXUIElement)
// directly to set the frontmost window's position onto the target display's
// corner, then warp the pointer and synthesize a click at the window's new
// center so macOS (and so paneru's active-display marker) switches to that
// display. The window keeps its current size in transit — floating,
// settling, verifying adoption, retrying, and the eventual resize to full
// width all live in config/paneru/lib/displays.lua (settle_after_move), using
// paneru's in-process Lua query API (paneru.query_active/query_json) rather
// than shelling out to `paneru query state` from here, so there's no
// subprocess spawn per settle check.
//
// Usage: move-display <app_name> <x> <y>
// <app_name> is the frontmost app to (re-)activate before teleporting, if it
// is not already frontmost; <x> <y> is the target display's origin in CG
// coordinates. Lua already has both from paneru.query_active()/display_frame().
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

let args = CommandLine.arguments
guard args.count == 4, let tx = Double(args[2]), let ty = Double(args[3]) else {
  FileHandle.standardError.write("usage: move-display <app_name> <x> <y>\n".data(using: .utf8)!)
  exit(1)
}
let appName = args[1]

// Re-activate the intended app first if focus drifted since Lua floated it.
if NSWorkspace.shared.frontmostApplication?.localizedName != appName,
   let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
  target.activate(options: [])
  Thread.sleep(forTimeInterval: 0.15)
}

guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
  FileHandle.standardError.write("no frontmost app\n".data(using: .utf8)!)
  exit(1)
}

let appElement = AXUIElementCreateApplication(pid)
var windowRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
      let windowRef else {
  FileHandle.standardError.write("no focused window\n".data(using: .utf8)!)
  exit(1)
}
let window = windowRef as! AXUIElement

var targetPoint = CGPoint(x: tx, y: ty)
guard let positionValue = AXValueCreate(.cgPoint, &targetPoint) else { exit(1) }
let setResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
guard setResult == .success else {
  FileHandle.standardError.write("set position failed: \(setResult.rawValue)\n".data(using: .utf8)!)
  exit(1)
}

// Read the window back (some apps clamp or adjust the requested position) to
// find its actual new center.
var positionRef: CFTypeRef?
var sizeRef: CFTypeRef?
AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
var actualPosition = CGPoint.zero
var actualSize = CGSize.zero
if let positionRef {
  _ = AXValueGetValue((positionRef as! AXValue), .cgPoint, &actualPosition)
}
if let sizeRef {
  _ = AXValueGetValue((sizeRef as! AXValue), .cgSize, &actualSize)
}
let center = CGPoint(x: actualPosition.x + actualSize.width / 2, y: actualPosition.y + actualSize.height / 2)

// Warp the pointer and synthesize a click at the window's new center so
// macOS treats the destination display as active — mirrors what a real
// click does, which is what makes paneru's active-display marker rotate.
CGWarpMouseCursorPosition(center)
CGAssociateMouseAndMouseCursorPosition(1)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
