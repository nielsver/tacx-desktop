#!/usr/bin/env bash
# Exercises packaging/linux/install.sh + uninstall.sh against a fake bundle
# in a throwaway XDG_DATA_HOME (path contains a space on purpose).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
B="$TMP/My Apps/tacx-desktop"; mkdir -p "$B/lib"
printf '#!/bin/sh\n' > "$B/tacx_desktop"
touch "$B/lib/libtacx_desktop_core.so"
cp "$ROOT"/packaging/linux/{install.sh,uninstall.sh,com.nielsver.tacx_desktop.png} "$B/"
chmod +x "$B"/*.sh
export XDG_DATA_HOME="$TMP/share"
D="$XDG_DATA_HOME/applications/com.nielsver.tacx_desktop.desktop"

"$B/install.sh"
[[ -x "$B/tacx_desktop" ]] || { echo "binary not executable"; exit 1; }
[[ -f "$XDG_DATA_HOME/icons/hicolor/256x256/apps/com.nielsver.tacx_desktop.png" ]] || { echo "icon missing"; exit 1; }
grep -qx "Exec=\"$B/tacx_desktop\"" "$D" || { echo "bad Exec line"; cat "$D"; exit 1; }
grep -qx "StartupWMClass=tacx_desktop" "$D" || { echo "bad WMClass"; exit 1; }
if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$D"; fi

# Missing core lib must refuse.
rm "$B/lib/libtacx_desktop_core.so"
if "$B/install.sh" 2>/dev/null; then echo "install should fail without core lib"; exit 1; fi

"$B/uninstall.sh"
[[ ! -e "$D" ]] || { echo "desktop file not removed"; exit 1; }
echo "linux install/uninstall OK"
