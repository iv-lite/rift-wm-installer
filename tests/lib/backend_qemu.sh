#!/usr/bin/env bash
# QEMU/KVM backend — runs the preview workflow on x86_64 Linux hosts.
# Intended to be sourced by tests/lib/common.sh.
#
# Runs a real macOS (Sequoia 15+) guest via QEMU/KVM + OVMF + OpenCore.
# Unlike the Tart backend there is no turnkey base image: you must provide an
# already-installed macOS system disk (a qcow2 that boots under OpenCore).
#
#   TESTS_MACOS_DISK   path to an installed macOS Sequoia qcow2 (required)
#   TESTS_OPENCORE     path to an OpenCore boot disk qcow2 (default: download
#                      kholia/OSX-KVM's OpenCore.qcow2.gz into tests/.preview-qemu)
#   TESTS_OVMF_CODE    OVMF firmware image (default /usr/share/OVMF/OVMF_CODE.fd)
#   TESTS_OVMF_VARS    OVMF variables template (default /usr/share/OVMF/OVMF_VARS.fd)
#   TESTS_SSH_PORT     host port forwarded to guest SSH (default 22222)
#
# The provided system disk is never written to: we boot writable qcow2
# overlays (bare.qcow2 / provisioned.qcow2) created by setup/snapshot.
# The guest account is expected to be admin/admin, like the Tart base images.
#
# Contract implemented: ensure_deps, cmd_setup, vm_exists, vm_is_running,
# vm_ip, vm_start, vm_stop, vm_delete, sync_repo, backend_screenshot,
# backend_snapshot, backend_restore, backend_clean.

VM="rift-test"
GUEST_DIR="$HOME/installer"
SSH_PORT_ARG="-p ${TESTS_SSH_PORT:-22222}"
SCP_PORT_ARG="-P ${TESTS_SSH_PORT:-22222}"

QEMU_DIR="$ROOT/tests/.preview-qemu"

ensure_deps() {
  if [ "${QEMU_DEPS_OK:-}" = "1" ]; then return 0; fi
  [ -e /dev/kvm ] || die "KVM is required (/dev/kvm missing) — enable virtualization in BIOS or run the macOS host backend instead"
  [ "$(uname -m)" = "x86_64" ] || die "macOS guests on Linux require an x86_64 host"
  local missing=""
  for bin in qemu-system-x86_64 qemu-img sshpass rsync; do
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
  done
  if [ -n "$missing" ]; then
    warn "missing required packages:$missing"
    echo "     Debian/Ubuntu:  sudo apt install qemu-system-x86 sshpass rsync python3"
    echo "     Fedora:         sudo dnf install qemu-system-x86 sshpass rsync python3"
    echo "     Arch:           sudo pacman -S qemu-system-x86 sshpass rsync python"
    die "install the missing packages, then re-run"
  fi
  QEMU_DEPS_OK=1
}

img_format() {
  qemu-img info "$1" 2>/dev/null | awk '/^file format:/{print $3}'
}

resolve_opencore() {
  if [ -n "${TESTS_OPENCORE:-}" ]; then
    echo "$TESTS_OPENCORE"
  elif [ -f "$QEMU_DIR/OpenCore.qcow2" ]; then
    echo "$QEMU_DIR/OpenCore.qcow2"
  else
    echo ""
  fi
}

cmd_setup() {
  ensure_deps
  mkdir -p "$QEMU_DIR"

  if [ -z "${TESTS_MACOS_DISK:-}" ]; then
    die "TESTS_MACOS_DISK is required on Linux: point it at an installed macOS Sequoia qcow2"
  fi
  [ -f "$TESTS_MACOS_DISK" ] || die "TESTS_MACOS_DISK '$TESTS_MACOS_DISK' does not exist"
  local fmt
  fmt="$(img_format "$TESTS_MACOS_DISK")"
  [ -n "$fmt" ] || die "TESTS_MACOS_DISK '${TESTS_MACOS_DISK}' is not a valid disk image"
  ok "Using macOS system disk: $TESTS_MACOS_DISK"

  local opencore
  opencore="$(resolve_opencore)"
  if [ -z "$opencore" ]; then
    note "Downloading OpenCore boot disk from kholia/OSX-KVM..."
    if curl -fL -o "$QEMU_DIR/OpenCore.qcow2.gz" \
        "https://github.com/kholia/OSX-KVM/releases/latest/download/OpenCore.qcow2.gz"; then
      gunzip -f "$QEMU_DIR/OpenCore.qcow2.gz"
      opencore="$QEMU_DIR/OpenCore.qcow2"
      ok "OpenCore downloaded"
    else
      rm -f "$QEMU_DIR/OpenCore.qcow2.gz"
      die "could not download OpenCore — set TESTS_OPENCORE to a local OpenCore.qcow2 (from github.com/kholia/OSX-KVM releases)"
    fi
  fi
  ok "OpenCore boot disk: $opencore"

  local ovmf_code="${TESTS_OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"
  local ovmf_vars="${TESTS_OVMF_VARS:-/usr/share/OVMF/OVMF_VARS.fd}"
  [ -f "$ovmf_code" ] || die "OVMF firmware not found at '$ovmf_code' — set TESTS_OVMF_CODE or install the 'ovmf' package"
  [ -f "$ovmf_vars" ] || die "OVMF vars not found at '$ovmf_vars' — set TESTS_OVMF_VARS or install the 'ovmf' package"
  if [ ! -f "$QEMU_DIR/OVMF_VARS.fd" ]; then
    cp "$ovmf_vars" "$QEMU_DIR/OVMF_VARS.fd"
  fi
  ok "OVMF firmware: $ovmf_code"

  if [ ! -f "$QEMU_DIR/bare.qcow2" ]; then
    note "Creating writable 'bare' overlay over the provided system disk..."
    qemu-img create -f qcow2 -F "$fmt" -b "$TESTS_MACOS_DISK" "$QEMU_DIR/bare.qcow2" >/dev/null
  fi
  if [ ! -f "$QEMU_DIR/current" ]; then
    echo "bare" >"$QEMU_DIR/current"
  fi

  echo ""
  warn "First boot must be watched once (GUI): confirm macOS boots, logs into"
  echo "     admin/admin, and that you can reach: ssh -p ${TESTS_SSH_PORT:-22222} admin@127.0.0.1"
  ok "Setup done — run: ./tests/preview up"
}

vm_exists() {
  [ -f "$QEMU_DIR/bare.qcow2" ]
}

vm_is_running() {
  [ -f "$QEMU_DIR/qemu.pid" ] && kill -0 "$(cat "$QEMU_DIR/qemu.pid")" 2>/dev/null
}

vm_ip() {
  echo "127.0.0.1"
}

vm_start() {
  [ -f "$QEMU_DIR/current" ] || { echo bare >"$QEMU_DIR/current"; }
  local disk="$QEMU_DIR/$(cat "$QEMU_DIR/current").qcow2"
  [ -f "$disk" ] || die "checked-out overlay '$disk' missing — run: ./tests/preview setup"

  local opencore
  opencore="$(resolve_opencore)"
  [ -n "$opencore" ] && [ -f "$opencore" ] || die "OpenCore boot disk missing — run: ./tests/preview setup"

  local display=""
  if [ "${1:-}" = "--no-graphics" ]; then
    warn "running headless — manual GUI grants will not be possible"
    display="-display none"
  elif [ -n "${DISPLAY:-}" ]; then
    display="-display gtk"
  elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
    display="-display wayland"
  else
    warn "no graphical display detected — running headless (screenshots still work via guest screencapture)"
    display="-display none"
  fi

  local ovmf_code="${TESTS_OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"
  [ -f "$ovmf_code" ] || die "OVMF firmware missing at '$ovmf_code' — run: ./tests/preview setup"

  nohup qemu-system-x86_64 \
    -name "$VM" \
    -machine q35,accel=kvm,usb=off \
    -cpu Haswell-v4,vendor=GenuineIntel,+ssse3,+sse4.2,+aes,+xsave,+avx,+xsaveopt,+avx2,+bmi2,+fma,+movbe,+invtsc,+pcid,+pdpe1gb \
    -smp 4 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$QEMU_DIR/OVMF_VARS.fd" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${TESTS_SSH_PORT:-22222}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -device ich9-ahci,id=sata \
    -drive id=opencore,if=none,format=qcow2,file="$opencore" \
    -device ide-hd,bus=sata.0,drive=opencore,bootindex=0 \
    -drive id=sys,if=none,format=qcow2,file="$disk" \
    -device virtio-blk-pci,drive=sys,bootindex=1 \
    -usb -device qemu-xhci -device usb-kbd -device usb-tablet \
    $display \
    >"$QEMU_DIR/qemu.log" 2>&1 &
  echo $! >"$QEMU_DIR/qemu.pid"
}

vm_stop() {
  if vm_is_running; then
    note "Stopping '$VM'..."
    kill "$(cat "$QEMU_DIR/qemu.pid")" 2>/dev/null || true
    local i=0
    while vm_is_running && [ "$i" -lt 20 ]; do
      sleep 1
      i=$((i + 1))
    done
    if vm_is_running; then
      warn "qemu did not exit cleanly — killing"
      kill -9 "$(cat "$QEMU_DIR/qemu.pid")" 2>/dev/null || true
      rm -f "$QEMU_DIR/qemu.pid"
    fi
    rm -f "$QEMU_DIR/qemu.pid"
  fi
}

vm_delete() {
  vm_stop
  rm -rf "$QEMU_DIR"
}

# rsync the repo into the guest so install always sees the latest files
# (the QEMU backend has no live host mount like Tart's --dir).
sync_repo() {
  guest "mkdir -p '$GUEST_DIR'"
  sshpass -p admin rsync -az \
    -e "sshpass -p admin ssh $SSH_PORT_ARG $SSH_OPTS" \
    --exclude '.git' \
    --exclude 'tests/.preview-qemu' \
    --exclude 'tests/screenshots' \
    --exclude '*.log' \
    "$ROOT/" "admin@127.0.0.1:installer/"
}

backend_screenshot() {
  local out="$1"
  guest "screencapture -x ~/preview-shot.png"
  scp_from_guest "~/preview-shot.png" "$out"
  guest "rm -f ~/preview-shot.png"
}

backend_snapshot() {
  vm_stop
  if [ -f "$QEMU_DIR/provisioned.qcow2" ]; then
    warn "snapshot 'provisioned' already exists — it stays the boot disk until 'restore bare'"
    return 0
  fi
  note "Creating 'provisioned' overlay of 'bare' (captures the current state)..."
  qemu-img create -f qcow2 -F qcow2 -b "$QEMU_DIR/bare.qcow2" "$QEMU_DIR/provisioned.qcow2" >/dev/null
  echo "provisioned" >"$QEMU_DIR/current"
  ok "snapshot 'provisioned' created — the VM now boots from it"
}

backend_restore() {
  local snap="${1:-bare}"
  if [ "$snap" != "bare" ] && [ "$snap" != "provisioned" ]; then die "snapshot must be 'bare' or 'provisioned'"; fi
  vm_stop
  case "$snap" in
    bare)
      if [ -f "$QEMU_DIR/provisioned.qcow2" ]; then
        note "Removing stale 'provisioned' overlay so the next provisioning run starts fresh..."
        rm -f "$QEMU_DIR/provisioned.qcow2"
      fi
      echo "bare" >"$QEMU_DIR/current"
      ;;
    provisioned)
      [ -f "$QEMU_DIR/provisioned.qcow2" ] || die "no 'provisioned' snapshot yet — run: ./tests/preview snapshot"
      echo "provisioned" >"$QEMU_DIR/current"
      ;;
  esac
  ok "restored to '$snap' — run: ./tests/preview up"
}

backend_clean() {
  local yn=""
  if [ -d "$QEMU_DIR" ]; then
    vm_stop
    [ -t 0 ] && read -p "  Delete test VM artifacts '$QEMU_DIR' (disk overlays, OpenCore, logs)? [y/N] " yn || yn=""
    case "$yn" in
      y|Y) vm_delete && ok "test VM artifacts deleted";;
      *)   note "kept VM artifacts";;
    esac
  fi
  echo ""
  note "System packages (qemu-system-x86, sshpass, rsync) were not removed —"
  echo "     they were installed at distro level. Remove them manually if no longer"
  echo "     needed, e.g.: sudo apt purge qemu-system-x86 sshpass"
  echo "     Your original macOS disk at TESTS_MACOS_DISK is never touched."
}