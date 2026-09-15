# rift-wm-installer

A niri-like window management setup for macOS, built on **Rift**
(`acsandmann/rift` — niri-style scrolling-strip tiler with hot-reloadable
TOML config, native menu-bar workspace indicators, and native multi-display
commands), **JankyBorders** (active-window focus border), and **Ghostty**
(terminal). Driven by Cmd+Option-key shortcuts that don't fight macOS
defaults.

## Requirements

- macOS 13+ (Rift; tested on Sequoia and later)
- Apple Silicon or Intel; Homebrew installed or auto-installed
- "Displays have separate Spaces" enabled (Rift-recommended; the installer sets it)
- No Karabiner, no disable of System Integrity Protection

## Quick start

```sh
./install
```

Re-running `./install` **upgrades** an existing setup: Homebrew components
(Rift, JankyBorders, Ghostty, tccutil-rs) are updated (no-op when current),
configs are refreshed from this repo (previous copies kept as `*.bak`), and
services are restarted so the new binaries/configs apply immediately.

The installer runs these steps from `scripts/`:

| Script | Purpose |
|---|---|
| `install-deps` | Install Homebrew if missing, tccutil-rs |
| `configure-system` | Enable "Displays have separate Spaces"; show the native menu bar (Rift draws its indicators in it) |
| `install-ghostty` | Install Ghostty + write `~/.config/ghostty/config` (frameless title bar) |
| `install-rift` | Install Rift (`acsandmann/tap`) + write `~/.config/rift/config.toml` + install the `cycle-column-width` helper + install its launchd service |
| `install-borders` | Install JankyBorders + write `~/.config/borders/bordersrc` |
| `install-helpers` | Install the shortcut cheat-sheet helpers into `~/.config/mac-scrolling-wm/helpers/` and install the macOS cheat-sheet viewer app (fetches a pre-built release from GitHub at `iv-lite/mac-cheatsheet-viewer`, falls back to a local source build) |
| `grant-permissions` | Grant Accessibility via tccutil-rs (user → sudo → manual fallback) |
| `enable-services` | Start Rift + JankyBorders |

### After install

1. **Log out and back in** (Cmd+Shift+Q) — applies the enabled
   separate-Spaces setting.
2. Rift tiles in a **niri-style scrolling strip**; workspaces `1..9` are
   persistent (fixed, not dynamic rows).
3. Rift draws **workspace badges in the native menu bar** — click a badge to
   switch. JankyBorders draws a border around the focused window.
4. If the Accessibility grant failed, grant it manually:
   System Settings → Privacy & Security → Accessibility (enable `rift`).
5. Ghostty opens **frameless** (`macos-titlebar-style = hidden` in
   `~/.config/ghostty/config`) — drag its window edge with `Option+Click`.

## Keybindings

Rift modifiers: **Cmd+Option** (window focus/state/columns), **Cmd+Ctrl**
(displays), **Ctrl+Option** (workspaces), **Shift** in any of those lanes
**moves** the focused window instead of just navigating.

> This keybinding scheme deliberately mirrors this repo's previous Paneru
> setup (not the plain-Option scheme from the earlier Rift era) so muscle
> memory carries over. See `config/rift/config.toml` `[keys]` for the exact
> table and `[modifier_combinations]` for the modifier-lane aliases (`main`,
> `mainShift`, `disp`, `dispShift`, `ws`, `wsShift`).

### Navigation & layout

| Shortcut | Action |
|---|---|
| `Cmd` + `Option` + Arrows | Move focus between windows |
| `Cmd` + `Option` + `Shift` + Arrows | Move window (swap) |
| 3-finger swipe (← / →) | Switch columns |
| `Cmd` + `Option` + `W` | Cycle the focused column width forward through 0.3 / 0.5 / 1.0 |
| `Cmd` + `Option` + `Shift` + `W` | Cycle the focused column width backward through the same presets |
| `Cmd` + `Option` + `M` | Jump the focused column straight to full width (stays tiled) |
| `Cmd` + `Option` + `Space` | Center the focused column |

### Workspaces (1-9, fixed)

| Shortcut | Action |
|---|---|
| `Ctrl` + `Option` + `↑` / `↓` | Previous/next workspace (via `rift-cli execute workspace prev\|next`) |
| `Cmd` + `Option` + `1..9` | Switch directly to workspace 1-9 |
| `Cmd` + `Option` + `Shift` + `1..9` | Move window to workspace 1-9 |
| `Cmd` + `Option` + `Tab` | Jump to the last-focused workspace |
| 3-finger swipe (↑ / ↓) | Switch workspaces (trackpad) |

> **Behavior change from Paneru:** Paneru's `Ctrl+Option+↑/↓` cycled
> *dynamically created/reaped* workspace rows (no fixed count). Rift's
> virtual workspaces are a **fixed, named set** — this config ships 9
> (`"1".."9"`), matching the workspace count from this repo's earlier
> Rift-era config. There is no on-demand row creation.

### Displays (multi-monitor)

| Shortcut | Action |
|---|---|
| `Cmd` + `Ctrl` + Arrows | Focus a display in that direction (window stays put) |
| `Cmd` + `Ctrl` + `Shift` + Arrows | Move the focused window to a display in that direction (follows) |
| `Cmd` + `Ctrl` + `Option` + Arrows | Warp only the mouse pointer to a display in that direction (no focus/window change) |

> **No helper binaries needed.** Rift has native directional display
> commands (`focus_display` / `move_window_to_display` in `[keys]`), unlike
> Paneru, which had no N-directional display support and needed
> `config/paneru/lib/displays.lua` plus four compiled/script helpers
> (`focus-display.swift`, `move-display.swift`, `display-geometry`,
> `mouse-display`) to work around it. All of that is gone — Rift resolves
> direction from actual display geometry itself.

### Window state

| Shortcut | Action |
|---|---|
| `Cmd` + `Option` + `V` | Toggle floating/tiled |
| `Cmd` + `Option` + `O` | Stack / unstack the window |
| `Cmd` + `Option` + `Ctrl` + `E` | Un-join the layout tree |
| `Cmd` + `Option` + `/` | Toggle orientation |

> **Removed vs. Paneru:** "balance columns", "equalize stack heights", and
> "copy window rule" have no Rift equivalent and were dropped rather than
> forced into a bad fit.

### Apps & misc

| Shortcut | Action |
|---|---|
| `Cmd` + `Ctrl` + `T` | Open Ghostty |
| `Cmd` + `Option` + `Shift` + `R` | Reload Rift config (hot reload is also on) |
| `Cmd` + `Shift` + `?` | Show the shortcut cheat sheet |

### Shortcut cheat sheet (Cmd+Shift+?)

`Cmd+Shift+?` runs `display-shortcuts`, which regenerates the cheat-sheet
JSON from the live Rift config and opens it in `mac-cheatsheet-viewer`, a
borderless always-on-top overlay (Esc / Cmd+W to close). The pieces:

- `helpers/generate-shortcuts-json` — parses the `[keys]` table (and
  `[modifier_combinations]` aliases) out of `~/.config/rift/config.toml`,
  humanizes the chords, and emits `~/.config/rift/cheatsheet.json` (curated
  action labels; unknown bindings fall back to their action name). This
  replaced a Lua-table parser when the config format changed back from
  Paneru's `init.lua` to Rift's TOML.
- `helpers/display-shortcuts` — runs the generator and opens the viewer.
- `mac-cheatsheet-viewer` — a separate repo (`iv-lite/mac-cheatsheet-viewer`)
  holding the Tauri app whose CLI arg is the JSON path. `install-helpers`
  fetches the `.app.zip` of the newest GitHub release and overwrites the
  installed bundle on every run. `MAC_WM_VIEWER_REPO` changes the repo,
  `MAC_WM_VIEWER_TAG` pins an exact tag; falls back to a local source build
  at `../mac-cheatsheet-viewer` if the fetch fails.

Installed helpers live in `~/.config/mac-scrolling-wm/helpers/` (copied on
`install`, removed by `uninstall`).

## The menu bar & notch

- **Workspace indicators** live in the **native menu bar**
  (`[settings.ui.menu_bar]` in `config/rift/config.toml`): badges for every
  workspace, click to switch. macOS already lays the menu bar around the
  notch, so no notch configuration is needed.
- **Focus cues** come from **JankyBorders** (`config/borders/bordersrc`) —
  Rift has no built-in window-border setting, so a small always-on service
  draws one. Colored to match the border from the previous Paneru setup.
- Tune the top gap if the menu bar extends over the notch area on a notched
  display — `[settings.layout.gaps.outer]` in `~/.config/rift/config.toml`.

## Multi-monitor

- Rift gives each display its own independent tiling layout and workspace
  set (with "Displays have separate Spaces" on).
- The scrolling strip **requires** displays arranged **vertically** in
  System Settings → Displays, even if they sit physically side-by-side —
  Rift's own docs note that side-by-side arrangement lets off-screen columns
  leak onto the other display (macOS puts all display coordinates in one
  shared space).
- Direction selectors (`left`/`right`/`up`/`down`) for every display command
  (`focus_display`, `move_window_to_display`, `move_mouse_to_display`) are
  resolved against **that macOS arrangement**, not physical desk placement —
  no manual offset/inversion setting needed, but it does mean that if your
  monitors are physically side-by-side and arranged vertically per the
  requirement above, the *up/down* keys are what actually move left/right in
  real life.
- **Physically moving the mouse to a screen edge only crosses to the next
  monitor if that edge matches the System Settings arrangement.** This is
  native macOS behavior, not something Rift controls — with vertical
  arrangement, only the top/bottom edges auto-cross, and there's no setting
  (unlike Paneru's old `horizontal_mouse_warp`) to fake a right-edge crossing
  while arranged vertically. Use the `Cmd+Ctrl+Option+Arrows` hotkey (warps
  just the pointer) or `Cmd+Ctrl+Arrows` (focuses the display) instead of
  relying on physical mouse movement for left/right navigation.
- Per-display gap overrides are supported in the config (commented template
  in `[settings.layout.gaps.per_display]`). Get display UUIDs with
  `rift-cli query displays`.

## No title bars (the macOS reality)

macOS tiling window managers (Rift included — same as yabai/AeroSpace/Paneru)
cannot hide a window's title bar or toolbar: each app draws its own chrome,
so removal has to happen per app. This installer does what's safely possible:

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

**Rift won't start / instantly exits.** Rift requires Accessibility and
"Displays have separate Spaces" **ON**. The installer's `configure-system` /
`ensure-separate-spaces` handles the latter. If grants failed, give the
terminal **Full Disk Access** first, then:

```sh
bash scripts/grant-permissions
rift service restart
```

A quick health check of the whole stack:

```sh
bash scripts/ensure-separate-spaces check   # must print "enabled (mode 1)"
RIFT_CLI_PRETTY=1 rift-cli query workspaces # must print a JSON snapshot (service up)
RIFT_CLI_PRETTY=1 rift-cli query displays   # lists connected monitors
```

**Config changes aren't applying.** Rift's config hot-reloads on save
(`hot_reload = true`); force it with `Cmd+Option+Shift+R`
(`reload_config`) or `rift-cli execute config reload`.

## Uninstall

```sh
./uninstall
```

Stops and removes Rift (launchd service) and JankyBorders, cleans up any
**legacy** Paneru / `rift-swipe` / AeroSpace / AeroSpaceBar / Aegis residue
(services, LaunchAgents, apps), moves configs (from `~/.config/rift`,
`~/.config/borders`, `~/.config/ghostty`, plus any legacy `~/.config/paneru`,
`~/.config/mac-scrolling-wm`, `~/.config/aerospace`, `~/.config/aegis`) to
`~/.config/backups/uninstall-<timestamp>/`, then asks you which formulae to
**keep** (interactive numbered menu). Untaps `acsandmann/tap`,
`FelixKratz/formulae`, `uinaf/tap` (and legacy `nikitabobko/tap`, `rdrkr/tap`
only when nothing kept depends on them), and restores the native menu bar.

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
./tests/preview check        # query Rift state + installed formulae
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
tested), Accessibility may need one manual grant inside the guest. The test
VM is named `rift-test`.

## Project layout

```
install                   Main installer (runs scripts/*)
uninstall                 Full uninstaller with interactive keep menu
scripts/                  Per-component install/system/accessibility steps,
                          plus cycle-column-width (deployed to
                          ~/.config/rift/, bound from config.toml's
                          Cmd+Option+W/Shift+W/M)
config/rift/              Rift config (scrolling strip, bindings, gaps, menu bar) — config.toml
config/borders/           JankyBorders focus-border config — bordersrc
config/ghostty/           Ghostty config (frameless title bar)
helpers/                  shortcut cheat-sheet: generate-shortcuts-json,
                          display-shortcuts (mac-cheatsheet-viewer app lives
                          in its own repo at iv-lite/mac-cheatsheet-viewer)
tests/                    VM test workflow (tests/preview + lib/ backends)
```

Configs are installed to `~/.config/{rift,borders,ghostty}` (plus shortcut
helpers under `~/.config/mac-scrolling-wm/`); existing files are backed up
(`.bak`) before overwriting, and Rift has `hot_reload`, so editing
`~/.config/rift/config.toml` applies live.

> **Note on the history:** an early version of this installer targeted
> AeroSpace (i3-style tree tiler) with AeroSpaceBar in the menu bar; a
> subsequent version used Rift (this same tool) with the plain-Option
> keybinding scheme from its upstream defaults; that was then replaced by
> **Paneru** (a different niri-style sliding-strip tiler with a Lua config)
> for its native infinite-strip paging. This version returns to **Rift**,
> now with a Cmd+Option keybinding scheme carried over from the Paneru era
> and JankyBorders back for the focus border Rift doesn't draw natively.
