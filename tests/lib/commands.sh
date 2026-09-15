#!/usr/bin/env bash
# Subcommands for the preview test workflow.
# Intended to be sourced by tests/preview after lib/common.sh (which loads
# the host backend). All commands act through the backend contract, so the
# same workflow runs on macOS hosts (Tart) and x86_64 Linux hosts (QEMU/KVM).

usage() {
  echo "Usage: ./tests/preview <command>"
  echo ""
  echo "Host is auto-detected: macOS -> Tart hypervisor, Linux x86_64 -> QEMU/KVM."
  echo "Running with no command defaults to: install requirements -> setup -> boot the VM."
  echo ""
  echo "  setup      Install deps, create the VM/disk layout (macOS: clones a"
  echo "             base image; Linux: requires TESTS_MACOS_DISK + boots once)"
  echo "  up         Boot the VM (GUI by default; --no-graphics for headless) and wait for SSH"
  echo "  install    Sync the repo into the guest and run ./install"
  echo "  access     Re-run the accessibility grant script in the guest"
  echo "  login      Log out/in the GUI session to apply the separate-Spaces setting"
  echo "  check      Query Rift state, separate-Spaces mode, installed formulae, and the Ghostty config in the guest"
  echo "  shot       Capture a screenshot into tests/screenshots/"
  echo "  snapshot   Create 'bare' (fresh macOS) + 'provisioned' (after install) snapshots"
  echo "  restore    Restore a snapshot: './tests/preview restore bare'"
  echo "  ssh        Open an interactive shell on the guest"
  echo "  stop       Gracefully stop the VM"
  echo "  delete     Stop and delete the VM entirely"
  echo "  clean      Interactively remove the test VM and its tools"
  echo ""
  echo "Linux-only environment variables: TESTS_MACOS_DISK, TESTS_OPENCORE,"
  echo "TESTS_OVMF_CODE, TESTS_OVMF_VARS, TESTS_SSH_PORT (default 22222)."
  echo "See tests/lib/backend_qemu.sh and README.md for details."
}

cmd_up() {
  local headless="${1:-}"
  if ! vm_exists; then die "VM does not exist — run: ./tests/preview setup"; fi
  if vm_is_running; then
    note "VM is already running ($(vm_ip))"
  else
    vm_start "$headless"
    wait_ssh
  fi
  echo ""
  ok "Connect anytime with:   ssh -p ${TESTS_SSH_PORT:-22} admin@$(vm_ip)"
}

cmd_install() {
  ensure_running
  note "Enabling passwordless sudo for 'admin' in guest..."
  guest_sudo "sh -c 'echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/100-admin && chmod 440 /etc/sudoers.d/100-admin'" || \
    warn "could not configure passwordless sudo — install may prompt for the admin password"
  note "Syncing repo into the guest (${GUEST_DIR})..."
  sync_repo
  note "Running install inside the guest..."
  guest "cd '${GUEST_DIR}' && ./install"
  ok "install finished in guest"
  warn "Re-run grants if Accessibility failed:  ./tests/preview access"
  ask_cleanup
}

cmd_access() {
  ensure_running
  sync_repo
  guest "bash '${GUEST_DIR}/scripts/grant-permissions'" || true
  warn "If grants failed above, open the VM window and grant manually:"
  warn "System Settings → Privacy & Security → Accessibility → enable Rift, Borders"
}

cmd_login() {
  ensure_running
  note "Restarting the login window to apply the separate-Spaces setting..."
  guest_sudo "killall loginwindow" || true
  sleep 15
  note "The GUI session is logging back in (auto-login)."
}

cmd_check() {
  ensure_running
  echo "── Separate Spaces (must be mode 1) ──"
  guest "\"${GUEST_DIR}/scripts/ensure-separate-spaces\" check" 2>&1 || true
  echo ""
  echo "── Rift service + state ──"
  guest "RIFT_CLI_PRETTY=1 rift-cli query workspaces" 2>&1 || true
  echo ""
  echo "── Installed formulae ──"
  guest "brew list | grep -Ei 'paneru|rift|aerospace|aerospacebar|borders|tccutil|ghostty' || echo '(none found)'"
  echo ""
  echo "── Aegis.app (should NOT be present) ──"
  guest "ls -d /Applications/Aegis.app 2>&1 || echo '(not installed — correct)'"
  echo ""
  echo "── Ghostty frameless config (should be present) ──"
  guest "grep -q 'macos-titlebar-style = hidden' ~/.config/ghostty/config && echo '(configured)' || echo '(missing)'"
  echo ""
  echo "── Shortcut helpers + cheat-sheet JSON (should be valid) ──"
  guest "test -x ~/.config/mac-scrolling-wm/helpers/generate-shortcuts-json && echo '(generator installed)' || echo '(missing)'"
  guest "test -x ~/.config/mac-scrolling-wm/helpers/display-shortcuts && echo '(launcher installed)' || echo '(missing)'"
  guest "ls -d ~/.config/mac-scrolling-wm/helpers/mac-cheatsheet-viewer.app >/dev/null 2>&1 && echo '(viewer app built)' || echo '(viewer app NOT built)'"
  guest "cd /tmp && ~/.config/mac-scrolling-wm/helpers/generate-shortcuts-json --output /tmp/cheatsheet.json && python3 -m json.tool /tmp/cheatsheet.json >/dev/null && echo '(cheat-sheet JSON valid — derived from live config.toml)' || echo '(cheat-sheet JSON INVALID)'"
  ask_cleanup
}

ask_cleanup() {
  if [ ! -t 0 ]; then
    note "Test finished — clean up later with: ./tests/preview clean"
    return 0
  fi
  echo ""
  local yn=""
  read -p "  Test finished. Clean up the test VM and tools now? [y/N] " yn
  case "$yn" in
    y|Y) cmd_clean;;
    *)   note "Kept everything — clean up later with: ./tests/preview clean";;
  esac
}

cmd_clean() {
  backend_clean
  echo ""
  ok "Cleanup finished."
}

cmd_shot() {
  ensure_running
  local outdir="$ROOT/tests/screenshots"
  mkdir -p "$outdir"
  local out="$outdir/shot-$(date +%Y%m%d-%H%M%S).png"
  backend_screenshot "$out"
  ok "screenshot saved: $out"
}

cmd_snapshot() {
  backend_snapshot
}

cmd_restore() {
  backend_restore "${1:-bare}"
}

cmd_ssh() {
  ensure_running
  local ip=""
  ip="$(vm_ip)"
  exec sshpass -p admin ssh $SSH_PORT_ARG $SSH_OPTS admin@"$ip"
}

cmd_stop() {
  vm_stop
  ok "VM stopped"
}

cmd_delete() {
  vm_stop
  vm_delete
  ok "VM deleted"
}