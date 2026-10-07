#!/usr/bin/env bash
# Cross-platform release build helper for Tacx Desktop (Flutter + Rust cdylib).
# Usage: ./scripts/build_release.sh [linux|windows|macos|all]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

target="${1:-linux}"

build_one() {
  local os="$1"
  echo "==> flutter build $os --release"
  case "$os" in
    linux)
      flutter build linux --release
      echo "Bundle: build/linux/x64/release/bundle/"
      echo "Ship the whole bundle/ folder (includes lib/ with Rust cdylib)."
      ;;
    windows)
      flutter build windows --release
      echo "Output: build/windows/x64/runner/Release/"
      echo "Zip the entire Release/ folder (exe + DLLs + data + Rust cdylib)."
      echo "Bluetooth: leave trainers UNPAIRED in Windows Settings → Bluetooth."
      echo "Quit Zwift/Tacx/MyWhoosh before first Connect."
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
