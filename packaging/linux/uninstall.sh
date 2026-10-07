#!/usr/bin/env bash
# Removes the launcher and icon added by install.sh. Leaves the app folder alone.
set -euo pipefail
APP_ID="com.nielsver.tacx_desktop"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
rm -f "$DATA_HOME/applications/$APP_ID.desktop" \
      "$DATA_HOME/icons/hicolor/256x256/apps/$APP_ID.png"
if command -v update-desktop-database >/dev/null; then update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true; fi
if command -v kbuildsycoca6 >/dev/null; then kbuildsycoca6 >/dev/null 2>&1 || true; fi
echo "Launcher removed. Delete the app folder yourself if you no longer need it."
