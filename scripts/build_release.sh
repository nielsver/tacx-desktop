#!/usr/bin/env bash
# Cross-platform release build helper for Tacx Desktop (Flutter + Rust cdylib).
# Usage: ./scripts/build_release.sh [linux|windows|macos|all]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

target="${1:-linux}"

zip_dir() {
  local src="$1"
  local out="$2"
  if [[ ! -d "$src" ]]; then
    echo "Missing output dir: $src" >&2
    return 1
  fi
  rm -f "$out"
  if command -v zip >/dev/null 2>&1; then
    (cd "$src" && zip -qr "$ROOT/$out" .)
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$src\\*' -DestinationPath '$ROOT\\$out' -Force"
  else
    echo "Install 'zip' to auto-pack; folder ready at: $src"
    return 0
  fi
  echo "Zip: $ROOT/$out"
}

build_one() {
  local os="$1"
  echo "==> flutter build $os --release"
  case "$os" in
    linux)
      flutter build linux --release
      echo "Bundle: build/linux/x64/release/bundle/"
      cp packaging/linux/FIRST_RUN.txt build/linux/x64/release/bundle/FIRST_RUN.txt
      echo "Ship the whole bundle/ tree (RPATH \$ORIGIN/lib → libtacx_desktop_core)."
      echo "Garuda: see FIRST_RUN.txt / scripts/garuda_first_run_smoke.sh"
      ver="local-$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
      pkg="tacx-desktop-linux-x64-${ver}.tar.gz"
      tar -C build/linux/x64/release -czf "$pkg" --transform 's,^bundle,tacx-desktop,' bundle
      echo "Tarball: $ROOT/$pkg"
      zip_dir "build/linux/x64/release/bundle" "tacx-desktop-linux-x64.zip" || true
      ;;
    windows)
      flutter build windows --release
      echo "Output: build/windows/x64/runner/Release/"
      echo "Bluetooth: leave trainers UNPAIRED in Windows Settings → Bluetooth."
      echo "Quit Zwift/Tacx/MyWhoosh before first Connect."
      echo "CI alternative: Actions → 'Windows release' (workflow_dispatch) uploads a zip artifact."
      zip_dir "build/windows/x64/runner/Release" "tacx-desktop-windows-x64.zip" || true
      ;;
    macos)
      flutter build macos --release
      echo "App: build/macos/Build/Products/Release/tacx_desktop.app"
      echo "Notarize for Gatekeeper if distributing outside your machine."
      echo "TCC: first launch prompts for Bluetooth — or enable in Privacy settings."
      ;;
    *)
      echo "Unknown target: $os" >&2
      exit 1
      ;;
  esac
}

if [[ "$target" == "all" ]]; then
  for t in linux windows macos; do build_one "$t"; done
else
  build_one "$target"
fi
