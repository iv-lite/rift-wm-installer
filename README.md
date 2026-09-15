# paneru-wm-installer

A niri-like window management setup for macOS, built on **Paneru** (sliding
infinite-strip tiler with hot-reloadable TOML config, native macOS workspaces
+ virtual workspaces, and a workspace status popup), and **Ghostty**
(terminal). Driven by Cmd+Option-key shortcuts that don't fight macOS defaults.

## Requirements

- macOS 14+ (Paneru)
- Apple Silicon
- Homebrew installed or auto-installed
- "Displays have separate Spaces" enabled (Paneru-recommended; the installer sets it)
- No Karabiner, no disable of System Integrity Protection

## Quick start

```sh
./install
```

Re-running `./install` **upgrades** an existing setup: Homebrew components
(Paneru, Ghostty, tccutil-rs) are updated (no-op when current), configs are
refreshed from this repo (previous copies kept as `*.bak`), and the service is
restarted so the new binary/config apply immediately.

The installer runs these steps from `scripts/`:

| Script | Purpose |
|---|---|
| `install-deps` | Install Homebrew if missing, tccutil-rs |
| `configure-system` | Enable "Displays have separate Spaces"; show the native menu bar (Paneru draws its indicator in it) |
| `install-ghostty` | Install Ghostty + write `~/.config/ghostty/config` (frameless title bar) |
| `install-paneru` | Install Paneru (Homebrew core) + write `~/.config/paneru/init.lua` + install its launchd service |
| `install-helpers` | Install the shortcut helpers into `~/.config/mac-scrolling-wm/helpers/` and install the macOS cheat-sheet viewer app (fetches a pre-built release from GitHub at `iv-lite/mac-cheatsheet-viewer`, falls back to a local source build) |
| `grant-permissions` | Grant Accessibility via tccutil-rs (user → sudo → manual fallback) |
| `enable-services` | Start Paneru |

### After install

1. **Log out and back in** (Cmd+Shift+Q) — applies the enabled
   separate-Spaces setting.
2. Paneru tiles in an **niri-style sliding strip**; new windows are appended at
   the end of the strip and **never resize existing windows**. Virtual
   workspaces are **dynamic rows** created on demand (and reaped when empty).
3. **Paneru** shows the active virtual workspace in a brief popup on switch.
4. If the Accessibility grant failed, grant it manually:
   System Settings → Privacy & Security → Accessibility (enable `paneru`,
   usually shown as `paneru` `/opt/homebrew/bin/paneru`).
5. Ghostty opens **frameless** (`macos-titlebar-style = hidden` in
   `~/.config/ghostty/config`) — drag its window edge with `Option+Click`.

## Keybindings

Paneru modifiers: **Cmd+Option** (columns), **Cmd+Ctrl** (displays),
**Ctrl+Option** (virtual workspace rows), **Shift** (**moves** the focused
window in the same lane), **Ctrl**.

### Navigation & layout

| Shortcut | Action |
|---|---|
| `Cmd` + `Option` + Arrows | Move focus between windows |
| 3-finger swipe (← / →) | Page through windows — one full-width window per swipe, snapping on release (`rift-swipe` is gone; Paneru snaps + focuses natively) |
| `Cmd` + `Option` + `Shift` + Arrows | Move window (swap) |
| `Cmd` + `Option` + `W` | Cycle the focused column width (0.3 / 0.5 / 1) |
| `Cmd` + `Option` + `Shift` + `W` | Cycle width backwards |
| `Cmd` + `Option` + `Space` | Center the focused window/viewport |
| `Cmd` + `Option` + `Shift` + `Space` | Snap an overflowing window into the viewport |
| `Cmd` + `Option` + `M` | Toggle full-width for the focused window |

> Focus **follows the mouse**, and keyboard navigation warps the cursor to the
> focused window (`focus_follows_mouse` / `mouse_follows_focus` in `[options]`).

### Workspaces (dynamic rows)

| Shortcut | Action |
|---|---|
| `Ctrl` + `Option` + `↑` / `↓` | Switch to the previous/next virtual workspace row (rows are created on demand past the last one) |
| `Ctrl` + `Option` + `Shift` + `↑` / `↓` | Move the focused window to the previous/next row and follow |
| 3-finger swipe (↑ / ↓) | Switch virtual workspace rows (trackpad) |
| `Cmd` + `Option` + `Tab` | Focus the last-focused window on this workspace |

> Workspace rows are **dynamic**: a new row spawns when you cross the last one
> and vanishes once it's empty (`create_virtual_workspace_automatically` /
> `reap_empty_workspaces` in `[options]`).

> Paneru virtual workspaces are stacks of horizontal strips *inside* a native
> macOS workspace. Each native Space (per display, with separate Spaces on) has
> its own strip and its own set of virtual workspaces.

### Displays (multi-monitor)

| Shortcut | Action |
|---|---|
| `Cmd` + `Ctrl` + `←` | Focus the previous display (window stays put) |
| `Cmd` + `Ctrl` + `→` | Focus the next display (window stays put) |
| `Cmd` + `Ctrl` + `Shift` + `←` | Move the focused window to the previous display (follow, maximized) |
| `Cmd` + `Ctrl` + `Shift` + `→` | Move the focused window to the next display (follow, maximized) |
| `Cmd` + `Ctrl` + `↑` | Warp the mouse to the next display |
| `Cmd` + `Option` + `↑`/`↓` | Focus a column above/below — crosses displays when no window is there |
| `Cmd` + `Option` + `Shift` + `↑`/`↓` | Move a window to the display above/below (when no window is there to swap with) |

> **Previous display is synthesized:** Paneru has no previous-direction
> display command (verified in Paneru's `argv` parser and
> `QUERY_AND_SUBSCRIBE_FORMAT.md`), so the focus-only shortcuts use a
> geometry-based Lua helper that orders displays by their macOS arrangement
> position (`y` then `x`) and picks the previous/next display via
> `ws:focus` — no window is moved.
>
> **Moving to any display needs a helper on 3+ monitors.** Paneru's engine
> can only move a window to a single fixed display (`other().next()`, the
> first spawned display that isn't the active one), which cannot reach
> every monitor on a three-or-more display setup — pressing the move
> shortcut just hops between two of them. With exactly two displays that
> one hop is correct (previous and next are the same display), so the
> move shortcuts keep using `window nextdisplay` there. With three or more
> they delegate to `~/.config/mac-scrolling-wm/helpers/move-display`:
> the script floats the focused window, teleports it onto the target
> display's frame via Accessibility, clicks it so macOS switches its
> active display (Paneru's active-display marker rotates along), and
> re-manages it so it is adopted by the target display's strip. It then
> **verifies the adoption** (`paneru query state`), polling the active
> display instead of sleeping so the OS's lagging display-change
> notification can't bounce the window back onto the source monitor. While
> a move is mid-flight the focused window is floating, and both the move and
> the focus shortcuts skip re-presses so targets are never computed off a
> stale "current" display.
>
> **Empty displays are reachable.** Paneru's Lua `display_of` resolves a
> window's display by *membership* in a strip, so a monitor with no windows
> used to be invisible and could not be focused or moved onto. The display
> geometry now comes from a helper (`helpers/display-geometry`) that lists
> every online display via CoreGraphics — empty ones included — and is cached
> in Lua, re-read on display events and whenever a window appears on an
> unknown display. Move targets an occupied *or* empty display (the helper
> teleports the window onto the blank monitor's frame and it is adopted by
> that strip). Focus on an empty display drops the pointer on its center
> (via `helpers/warp-pointer`), the same idea as Paneru's native
> `mouse nextdisplay`, so the OS and the next move target it.
>
> One-time cost: grant Accessibility access to System Events (macOS
> prompts on first teleport).

### Window state

| Shortcut | Action |
|---|---|
| `Cmd` + `Option` + `V` | Toggle floating/tiled |
| `Cmd` + `Option` + `O` | Stack the window into the neighbouring column |
| `Cmd` + `Option` + `Shift` + `O` | Pull a window out of a stack |
| `Cmd` + `Option` + `B` | Balance all columns to the focused window's width |
| `Cmd` + `Option` + `Shift` + `E` | Equalize the heights in a stack |
| `Cmd` + `Option` + `Shift` + `C` | Copy a Paneru window rule for the focused window |
| `Cmd` + `Option` + `Ctrl` + `Q` | Quit Paneru |

### Apps & misc

| Shortcut | Action |
|---|---|
| `Cmd` + `Option` + `Shift` + `R` | Restart Paneru (config also live-reloads on save) |
| `Cmd` + `Shift` + `?` | Show the shortcut cheat sheet (regenerates the JSON from `init.lua`, then opens `mac-cheatsheet-viewer`) |

### Shortcut cheat sheet (Cmd+Shift+?)

`Cmd+Shift+?` runs `display-shortcuts`, which regenerates the cheat-sheet JSON
from the live Paneru config and opens it in `mac-cheatsheet-viewer`, a
borderless always-on-top overlay (Esc / Cmd+W to close). The pieces:

- `helpers/generate-shortcuts-json` — parses the `BINDINGS` table in
  `~/.config/paneru/init.lua`, humanizes the chords, and emits
  `~/.config/paneru/cheatsheet.json` (curated action labels; unknown bindings
  fall back to their command name).
- `helpers/display-shortcuts` — runs the generator and opens the viewer.
- `helpers/move-display` — the 3+ display window mover (see "Displays
  (multi-monitor)"): floats the focused window, teleports it onto the target
  display via Accessibility, clicks it to rotate Paneru's active-display
  marker, and re-manages it, polling `paneru query state` to verify it was
  adopted by the target strip. Needs one-time Accessibility access for System
  Events; logs to `move-display.log` next to itself.
- `mac-cheatsheet-viewer` — a separate repo (`iv-lite/mac-cheatsheet-viewer`)
  holding the Tauri app (static vanilla frontend, no npm) whose CLI arg is the
  JSON path; it validates strictly (`cheatsheet-core` crate) and renders
  bordered groups. `install-helpers` fetches the `.app.zip` of the **newest
  release in the GitHub release list** (the special-latest endpoint is never
  used; prereleases are included, drafts excluded, releases without the asset
  skipped) and overwrites the installed bundle on every run.
  `MAC_WM_VIEWER_REPO` changes the repo, `MAC_WM_VIEWER_TAG` pins an exact
  tag; a CI workflow in that repo builds DMG + `.app` releases for every `v*`
  tag. If the fetch fails, it falls back to a local source build at
  `../mac-cheatsheet-viewer`.
- Paneru itself runs the launcher via its Lua API
  (`paneru.exec`), which is why the config is `init.lua` (a Lua config
  replaces the legacy `paneru.toml`; TOML bindings cannot launch scripts).

Installed helpers live in `~/.config/mac-scrolling-wm/helpers/` (copied on
`install`, removed by `uninstall`).

> **Removed vs. the Rift/AeroSpace setups:** fine-grained resizing
> (`Option+Ctrl+arrows` step-resize), fullscreen toggles, per-Space tiling
> toggles (`Alt+Z`), strip scroll half-steps (`Alt+[`/`]`), and an
> `open-terminal` shortcut have no Paneru equivalent and were dropped. The
> SketchyBar cheat sheet is long gone — Paneru draws the workspace indicator in
> the (native) menu bar.

### The infinite horizontal canvas

The niri-style sliding strip behaves like a canvas **wider than the monitor**:
unfocused windows park off-screen and glide in/out of the screen edges as focus
moves. Two things make it feel native:

- Paneru keeps a thin **sliver** of each off-screen window visible at the
  screen edge (`sliver_width` / `sliver_height` in the config) — a workaround
  for macOS relocating windows that move fully off-screen, not a design choice.
- `swipe.continuous = false` bounds the strip to its left/right-most window,
  so a full 3-finger swipe lands exactly on the next full-width window
  (page-flip).
- `options.preset_column_widths = { 0.3, 0.5, 1.0 }` cycling and
  `window_fullwidth` (Cmd+Option+M) cover on-demand sizing; new windows are
  appended at the end and never resize existing ones.

## The menu bar

- The **native macOS menu bar** is kept. The menu-bar workspace indicator is
  **disabled by default** (`decorations` in `~/.config/paneru/init.lua`,
  `workspace_menu_status = false`) because Paneru < the fix in
  [karinushka/paneru#390](https://github.com/karinushka/paneru/issues/390)
  hosts a live view in the status item, and its AppKit redraw loop starves the
  run loop that services Paneru's `CGEventTap` — keybindings silently die after
  leaving native fullscreen. A brief status popup still announces the active
  workspace on switch; re-enable the indicator once a Paneru release ships #390.
- **Focus cues**: an active-window border (`decorations.active.border`, Nord
  blue) replaces JankyBorders — no extra bar process needed. Inactive-window
  dimming uses native macOS (`decorations.inactive.dim`).
- **Top gap:** `padding.top` defaults to 15px in the config.

## No title bars (the macOS reality)

macOS tiling window managers (Paneru included — same as yabai/AeroSpace) cannot
hide a window's title bar or toolbar: each app draws its own chrome, so removal
has to happen per app. This installer does what's safely possible:

- **Ghostty is frameless by default** — `~/.config/ghostty/config` sets
  `macos-titlebar-style = hidden` and `macos-window-buttons = hidden` (keeps
  rounded corners and borders). Drag the window by its edge with `Option+Click`.
- **Other apps:** use each app's native toggle:
  | App | How |
  |---|---|
  | Finder, Mail, Notes, Safari, Chrome, Slack | `View → Hide Toolbar` (often `Cmd+Option+T`) |
  | Safari fullscreen | `View → Always Show Toolbar in Full Screen` off |
  | Ghostty | handled for you above |
  | VS Code | no clean path since 1.94 (hair-line third-party extensions only — not shipped) |

> Global tools that strip titlebars everywhere (e.g. `Brutalium`, `winBuddy`)
> inject code into running apps and require disabling SIP — out of scope here,
> the same reason this project never disables SIP.

## Troubleshooting

**Shortcuts become unresponsive after toggling off full screen.** Upstream bug
[karinushka/paneru#390](https://github.com/karinushka/paneru/issues/390): the
menu-bar workspace indicator's live view starves the run loop that services
Paneru's `CGEventTap`, so macOS disables the tap and keybindings (clicks and
swipes too) silently stop working. This repo works around it by shipping
`workspace_menu_status = false` (workspace switches are still announced by the
popup). Immediate recourse: `paneru restart`. Re-enable the indicator once a
Paneru release includes the #390 fix; concurrently, keep Paneru at ≥ 0.5.0 so
the event-tap watchdog (karinushka/paneru#350) is present.

**Paneru won't start / instantly exits.** Paneru hard-exits unless it has
Accessibility and "Displays have separate Spaces" is **ON**. The installer's
`configure-system` / `ensure-separate-spaces` handles the latter. If grants
failed, give the terminal **Full Disk Access** first, then:

```sh
bash scripts/grant-permissions
paneru restart
```

Paneru's own debug trail: `paneru printstate` (via `paneru send-cmd printstate`),
logs from its LaunchAgent, and the interactive `paneru` front-run for the same
output. A quick health check of the whole stack:

```sh
bash scripts/ensure-separate-spaces check   # must print "enabled (mode 1)"
paneru query state --json                   # must print a JSON snapshot (service up)
```

## Multi-monitor

- Paneru gives each display its **own independent window strip** and its own
  set of native workspaces (with "Displays have separate Spaces" on).
- The shipped config targets **horizontally stacked** (side-by-side) monitors:
  arrange the displays **vertically** in System Settings → Displays (laptop
  above/below the external monitor) but place them physically side-by-side.
  `horizontal_mouse_warp = -1` (in `options` in `config/paneru/init.lua`) then
  makes the cursor cross screen edges left↔right exactly as if the monitors
  were side-by-side — matching macOS's native behavior while keeping Paneru's
  vertical display traversal intact.
- If one display physically sits higher or lower than the other (e.g. a
  portrait monitor on a stand), adjust `horizontal_mouse_warp_offset` (px) to
  line the warp landing up with the desk positions.
- A window can be sent to another display with `Cmd+Ctrl+→` (follow) or
  `Cmd+Ctrl+Shift+→` (stay), and `Cmd+Ctrl+↑` warps the mouse there.

## Uninstall

```sh
./uninstall
```

Stops and removes Paneru (launchd service) and its app launcher, cleans up any
**legacy** Rift / `rift-swipe` / JankyBorders / AeroSpace / AeroSpaceBar / Aegis
residue (services, LaunchAgents, apps), moves configs (from `~/.config/paneru`,
`~/.config/ghostty`, plus any legacy `~/.config/rift`, `~/.config/borders`,
`~/.config/aerospace`, `~/.config/aegis`, `~/.paneru*`, and Paneru's state dir)
to `~/.config/backups/uninstall-<timestamp>/`, then asks you which formulae to
**keep** (interactive numbered menu). Untaps `acsandmann/tap`,
`FelixKratz/formulae` (and legacy `nikitabobko/tap`, `rdrkr/tap` only when
nothing kept depends on them), and restores the native menu bar.

## Testing in a macOS VM

The `tests/preview` workflow runs `./install` inside a real macOS guest VM.
The host OS is auto-detected and a matching hypervisor backend is used:

| Host | Backend | Requirements |
| --- | --- | --- |
| macOS (Apple Silicon) | Tart (`tests/lib/backend_tart.sh`) | macOS 15+, Homebrew; `tart`/`sshpass` auto-installed |
| Linux x86_64 | QEMU/KVM + OpenCore (`tests/lib/backend_qemu.sh`) | `/dev/kvm`, `qemu-system-x86`, `sshpass`, `rsync`, a macOS Sequoia disk |

macOS host:

```sh
./tests/preview setup        # installs tart/sshpass (auto), clones host-matched base image
./tests/preview up           # boot guest, live-mount the repo, wait for SSH
./tests/preview install      # run ./install in the guest (asks to clean up afterwards)
./tests/preview check        # query Paneru state + installed formulae
./tests/preview shot         # screenshot the tiling into tests/screenshots/
./tests/preview clean        # interactively remove VM, tart, sshpass, base image
```

Linux x86_64 host:

```sh
export TESTS_MACOS_DISK=/path/to/macos-sequoia.qcow2   # required (installed guest, admin/admin)
./tests/preview setup        # validates the disk, fetches OpenCore, creates qcow2 overlays
./tests/preview up           # boot the guest (watch the first boot once to confirm login)
./tests/preview install      # rsyncs the repo into the guest, then runs ./install
./tests/preview check
./tests/preview shot
./tests/preview clean
```

On Linux the provided `TESTS_MACOS_DISK` is never written to — the VM boots
writable qcow2 overlays (`tests/.preview-qemu/bare.qcow2`,
`provisioned.qcow2`). Bare/provisioned snapshots follow the same semantics as
Tart: `snapshot` captures the current state into `provisioned`, `restore bare`
resets to the golden baseline. Extra tunables are documented in
`tests/lib/backend_qemu.sh` (`TESTS_OPENCORE`, `TESTS_OVMF_CODE`,
`TESTS_OVMF_VARS`, `TESTS_SSH_PORT`, default 22222).

On macOS, dependencies (`tart`, `sshpass`) are installed automatically on
demand and can be removed with `clean`; on Linux, failing-check hints print
the distro package install commands. See `./tests/preview help` for the full
command list. Limitations: single virtual display (multi-monitor can't be
tested), Accessibility may need one manual grant inside the guest.

## Project layout

```
install                   Main installer (runs scripts/*)
uninstall                 Full uninstaller with interactive keep menu
scripts/                  Per-component install/system/accessibility steps
config/paneru/            Paneru config (sliding strip, bindings, rules) — init.lua
config/ghostty/           Ghostty config (frameless title bar)
helpers/                  shortcut cheat-sheet: generate-shortcuts-json,
                          display-shortcuts (mac-cheatsheet-viewer app lives in
                          its own repo at iv-lite/mac-cheatsheet-viewer)
tests/                    VM test workflow (tests/preview + lib/ backends)
```

Configs are installed to `~/.config/{paneru,ghostty}` (plus shortcut helpers
under `~/.config/mac-scrolling-wm/`);
existing files are backed up (`.bak`) before overwriting, and Paneru
hot-reloads `~/.config/paneru/init.lua`, so edits apply live.

> **Note on the history:** an early version of this installer targeted
> AeroSpace (i3-style tree tiler) with AeroSpaceBar in the menu bar; a later
> version used **Rift** (niri-style scrolling strip) plus a custom `rift-swipe`
> C helper repurposing Rift's pan-only gesture. This version is on **Paneru**
> (niri-style sliding strip), which pages windows + snaps + focuses on gesture
> release natively — so the Rift-era helper, its LaunchAgent, JankyBorders, and
> the `cycle-column-width` Python helper are all gone, and BSP/border chromes
> come from Paneru itself.