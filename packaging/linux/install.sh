#!/usr/bin/env bash
# Adds Tacx Desktop to the KDE/GNOME app launcher for the current user.
# Run from the extracted bundle:  cd ~/Apps/tacx-desktop && ./install.sh
# Nothing is copied outside ~/.local; the app keeps running from this folder.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run as root: BlueZ needs your normal desktop session." >&2
  exit 1
fi

APP_ID="com.nielsver.tacx_desktop"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/tacx_desktop"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATA_HOME/applications"
ICONS="$DATA_HOME/icons/hicolor/256x256/apps"

[[ -f "$BIN" ]] || { echo "tacx_desktop not found next to install.sh ($DIR)" >&2; exit 1; }
compgen -G "$DIR/lib/*tacx_desktop_core*" >/dev/null \
  || { echo "lib/libtacx_desktop_core.so missing: extract the whole tarball, not just the binary." >&2; exit 1; }
chmod +x "$BIN"

mkdir -p "$APPS" "$ICONS"
cp "$DIR/$APP_ID.png" "$ICONS/$APP_ID.png"

# Paths with spaces are quoted per the Desktop Entry spec.
cat > "$APPS/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.5
Name=Tacx Desktop
GenericName=Smart trainer control
Comment=Control a Tacx / FTMS smart trainer over Bluetooth (ERG, resistance, simulation)
Exec="$BIN"
Path=$DIR
Icon=$APP_ID
Terminal=false
Categories=Utility;
Keywords=tacx;trainer;ftms;fec;erg;bike;cycling;bluetooth;
StartupNotify=true
StartupWMClass=tacx_desktop
DESKTOP

if command -v update-desktop-database >/dev/null; then update-desktop-database "$APPS" >/dev/null 2>&1 || true; fi
if command -v gtk-update-icon-cache >/dev/null; then gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true; fi
if command -v kbuildsycoca6 >/dev/null; then kbuildsycoca6 >/dev/null 2>&1 || true; fi

echo "Installed launcher: $APPS/$APP_ID.desktop"
echo "Find \"Tacx Desktop\" in the app menu. Remove with ./uninstall.sh"
