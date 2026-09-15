#!/usr/bin/env bash
# Tart backend — runs the preview workflow on Apple Silicon macOS hosts.
# Intended to be sourced by tests/lib/common.sh.
#
# Uses Tart (Apple Virtualization.framework): clones a host-matched macOS
# base image, mounts the repo via --dir (live 'My Shared Files' share) and
# lives before/inside tests/ the same way the original single-host workflow
# did.
#
# Contract implemented: ensure_deps, cmd_setup, vm_exists, vm_is_running,
# vm_ip, vm_start, vm_stop, vm_delete, sync_repo, backend_screenshot,
# backend_snapshot, backend_restore, backend_clean.

VM="rift-test"
MOUNT_NAME="installer"
GUEST_DIR="/Volumes/My Shared Files/${MOUNT_NAME}"
SSH_PORT_ARG=""
SCP_PORT_ARG=""

base_image() {
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  case "$major" in
    26) echo "ghcr.io/cirruslabs/macos-tahoe-base:latest";;
    15) echo "ghcr.io/cirruslabs/macos-sequoia-base:latest";;
    14) echo "ghcr.io/cirruslabs/macos-sonoma-base:latest";;
    13) echo "ghcr.io/cirruslabs/macos-ventura-base:latest";;
    *)  die "cannot map host macOS major version '$major' to a Tart base image";;
  esac
}

vm_exists() {
  tart list 2>/dev/null | awk -v vm="$VM" '$1 ~ "^"vm"$" { found=1 } END { exit !found }'
}

vm_is_running() {
  tart list 2>/dev/null | awk -v vm="$VM" '$1 ~ "^"vm"$" && $0 ~ /running/ { found=1 } END { exit !found }'
}

vm_ip() {
  tart ip "$VM" 2>/dev/null || echo ""
}

vm_start() {
  local extra=""
  if [ "${1:-}" = "--no-graphics" ]; then extra="--no-graphics"; fi
  if [ -n "$extra" ]; then warn "running headless — manual GUI grants will not be possible"; fi
  nohup tart run "$VM" --dir "${MOUNT_NAME}:${ROOT}" $extra >"$ROOT/tests/.tart-run.log" 2>&1 &
}

vm_stop() {
  if vm_is_running; then
    note "Stopping '$VM'..."
    tart stop "$VM" || true
  fi
}

vm_delete() {
  tart delete "$VM"
}

ensure_deps() {
  if [ "${TART_DEPS_OK:-}" = "1" ]; then return 0; fi
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required — install it first (./install can do this)"
  fi
  local need=""
  if ! command -v tart >/dev/null 2>&1; then need="$need cirruslabs/cli/tart"; fi
  if ! command -v sshpass >/dev/null 2>&1; then need="$need cirruslabs/cli/sshpass"; fi
  if [ -n "$need" ]; then
    note "Trusting and tapping cirruslabs/cli (required for tart/sshpass)..."
    brew trust cirruslabs/cli 2>/dev/null || true
    brew tap cirruslabs/cli
    note "Installing missing requirements:$need"
    brew install $need
  fi
  TART_DEPS_OK=1
}

cmd_setup() {
  ensure_deps
  local image
  image="$(base_image)"
  if ! vm_exists; then
    note "Cloning $image (first run downloads ~25 GB)..."
    tart clone "$image" "$VM"
  else
    ok "VM '$VM' already exists — skipping clone"
  fi
  note "Tuning resources (4 CPU / 8 GB)..."
  tart set "$VM" --cpus 4 --memory 8192 2>/dev/null || true
  ok "Setup done — run: ./tests/preview up"
}

# Tart mounts the repo live; nothing to copy.
sync_repo() {
  :
}

backend_screenshot() {
  local out="$1"
  tart screenshot "$VM" "$out"
}

backend_snapshot() {
  vm_stop
  for snap in bare provisioned; do
    if tart snapshot "$VM" "$snap" 2>/dev/null; then
      ok "snapshot '$snap' created"
    else
      warn "snapshot '$snap' failed (may already exist)"
    fi
  done
}

backend_restore() {
  local snap="${1:-bare}"
  if [ "$snap" != "bare" ] && [ "$snap" != "provisioned" ]; then die "snapshot must be 'bare' or 'provisioned'"; fi
  vm_stop
  tart restore "$VM" "$snap"
  ok "restored to '$snap' — run: ./tests/preview up"
}

backend_clean() {
  local yn=""
  local has_tart="no"
  command -v tart >/dev/null 2>&1 && has_tart="yes"

  if [ "$has_tart" = "yes" ] && vm_exists 2>/dev/null; then
    vm_stop
    [ -t 0 ] && read -p "  Delete test VM '$VM' and its snapshots? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) vm_delete && ok "test VM deleted";;
      *)   note "kept VM '$VM'";;
    esac
  fi

  if command -v tart >/dev/null 2>&1; then
    [ -t 0 ] && read -p "  Uninstall tart? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) brew uninstall tart; ok "tart uninstalled";;
      *)   note "kept tart";;
    esac
  fi

  if command -v sshpass >/dev/null 2>&1; then
    [ -t 0 ] && read -p "  Uninstall sshpass? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) brew uninstall sshpass; ok "sshpass uninstalled";;
      *)   note "kept sshpass";;
    esac
  fi

  if command -v tart >/dev/null 2>&1; then
    local image=""
    image="$(base_image)" 2>/dev/null || true
    [ -t 0 ] && read -p "  Also delete base image '$image' (~25 GB, re-download needed later)? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) tart delete "$image" 2>/dev/null && ok "base image deleted" || warn "could not delete base image (does it exist?)";;
      *)   note "kept base image";;
    esac
  fi

  if brew tap 2>/dev/null | grep -q "^cirruslabs/cli$"; then
    [ -t 0 ] && read -p "  Untap cirruslabs/cli? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) brew untap cirruslabs/cli >/dev/null 2>&1; brew untrust cirruslabs/cli >/dev/null 2>&1 || true; ok "tap cirruslabs/cli removed";;
      *)   note "kept tap cirruslabs/cli";;
    esac
  fi
}