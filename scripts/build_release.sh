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
      cp packaging/linux/FIRST_RUN.txt packaging/linux/install.sh packaging/linux/uninstall.sh          packaging/linux/com.nielsver.tacx_desktop.png build/linux/x64/release/bundle/
      chmod +x build/linux/x64/release/bundle/install.sh build/linux/x64/release/bundle/uninstall.sh
      echo "Ship the whole bundle/ tree (RPATH \$ORIGIN/lib → libtacx_desktop_core)."
      echo "Garuda: see FIRST_RUN.txt / scripts/garuda_first_run_smoke.sh"
      ver="local-$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
      pkg="tacx-desktop-linux-x64-${ver}.tar.gz"
      tar -C build/linux/x64/release -czf "$pkg" --transform 's,^bundle,tacx-desktop,' bundle
      echo "Tarball: $ROOT/$pkg"
      zip_dir "build/linux/x64/release/bundle" "tacx-desktop-linux-x64.zip" || true
      # Optional local AppImage / .deb (skip if tools missing)
      if command -v curl >/dev/null 2>&1; then
        ./scripts/package_linux_appimage.sh build/linux/x64/release/bundle "$ver" "$ROOT" || \
          echo "AppImage skipped (appimagetool/FUSE?)"
      fi
      if command -v dpkg-deb >/dev/null 2>&1; then
        ./scripts/package_linux_deb.sh build/linux/x64/release/bundle "${ver#v}" "$ROOT" || \
          echo ".deb skipped"
      fi
      ;;
    windows)
      flutter build windows --release
      echo "Output: build/windows/x64/runner/Release/"
      echo "Bluetooth: leave trainers UNPAIRED in Windows Settings → Bluetooth."
      echo "Quit Zwift/Tacx/MyWhoosh before first Connect."
      echo "CI: Actions → Release builds zip + TacxDesktop-Setup-*.exe (Inno)."
      zip_dir "build/windows/x64/runner/Release" "tacx-desktop-windows-x64.zip" || true
      if command -v pwsh >/dev/null 2>&1; then
        pwsh -File ./scripts/package_windows_installer.ps1 || echo "Inno Setup skipped (install Inno Setup 6)"
      fi
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
