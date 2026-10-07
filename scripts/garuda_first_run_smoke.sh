#!/usr/bin/env bash
# Garuda / Arch first-run smoke for Tacx Desktop release tar.gz.
# Usage:
#   ./scripts/garuda_first_run_smoke.sh [path/to/tacx-desktop-linux-x64-*.tar.gz]
#   ./scripts/garuda_first_run_smoke.sh   # OS BT checks only, then looks for ~/Apps/tacx-desktop
set -euo pipefail

echo "==> BlueZ / runtime packages"
sudo pacman -S --needed bluez bluez-utils bluez-libs gtk3 libepoxy xz util-linux

echo "==> Enable bluetoothd"
sudo systemctl enable --now bluetooth
systemctl is-active bluetooth

if ! groups | grep -q bluetooth; then
  echo "Adding $USER to bluetooth group — log out/in, then re-run this script."
  sudo usermod -aG bluetooth "$USER"
  exit 0
fi

rfkill unblock bluetooth 2>/dev/null || true
bluetoothctl power on || true
bluetoothctl show | grep -E 'Powered|Discovering' || true
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-<unset — use Plasma/SDDM login, never raw tty without session bus>}"

ARCHIVE="${1:-}"
DEST="${HOME}/Apps/tacx-desktop"

if [[ -n "$ARCHIVE" ]]; then
  [[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE" >&2; exit 1; }
  echo "==> Extract $ARCHIVE → ~/Apps"
  mkdir -p "${HOME}/Apps"
  tar -xzf "$ARCHIVE" -C "${HOME}/Apps"
fi

if [[ ! -d "$DEST" ]]; then
  echo "No $DEST yet. Download Release artifact tacx-desktop-linux-x64, then:"
  echo "  $0 /path/to/tacx-desktop-linux-x64-*.tar.gz"
  exit 0
fi

cd "$DEST"
chmod +x ./tacx_desktop
echo "==> Bundled Rust cdylib"
ls lib | grep -i tacx_desktop_core
echo "==> ldd (must show no 'not found')"
if ldd ./tacx_desktop | grep 'not found'; then
  echo "Install missing libs: sudo pacman -S gtk3 libepoxy xz util-linux" >&2
  exit 1
fi
echo "ldd OK"
echo
echo "Run:  cd $DEST && ./tacx_desktop"
echo "Fallback: GDK_BACKEND=x11 ./tacx_desktop"
echo "If shared lib miss: export LD_LIBRARY_PATH=\"\$PWD/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
echo "In app: Demo smoke → Demo off → quit other apps → forget KDE pairing → Scan → Connect → ERG"
