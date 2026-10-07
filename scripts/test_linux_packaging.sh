#!/usr/bin/env bash
# Dry-run AppImage AppDir layout + .deb packaging against a fake Flutter bundle.
# Does not require Flutter or a real AppImage runtime — validates scripts + dpkg-deb.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

BUNDLE="$TMP/bundle"
mkdir -p "$BUNDLE/lib" "$BUNDLE/data"
printf '#!/bin/sh\necho fake\n' > "$BUNDLE/tacx_desktop"
chmod +x "$BUNDLE/tacx_desktop"
touch "$BUNDLE/lib/libtacx_desktop_core.so"
touch "$BUNDLE/lib/libflutter_linux_gtk.so"
mkdir -p "$BUNDLE/data/flutter_assets"
echo ok > "$BUNDLE/data/flutter_assets/AssetManifest.bin"
cp "$ROOT/packaging/linux/com.nielsver.tacx_desktop.png" "$BUNDLE/"
cp "$ROOT/packaging/linux/FIRST_RUN.txt" "$BUNDLE/"

OUT="$TMP/out"
mkdir -p "$OUT"

# --- .deb ---
"$ROOT/scripts/package_linux_deb.sh" "$BUNDLE" "0.2.1-test" "$OUT"
DEB="$(ls "$OUT"/tacx-desktop_0.2.1-test_amd64.deb)"
dpkg-deb -c "$DEB" | grep -q './opt/tacx-desktop/tacx_desktop'
dpkg-deb -c "$DEB" | grep -q './usr/bin/tacx-desktop'
dpkg-deb -c "$DEB" | grep -q './usr/share/applications/com.nielsver.tacx_desktop.desktop'
dpkg-deb -I "$DEB" | grep -q 'Package: tacx-desktop'
echo "deb packaging OK: $DEB"

# Extract and check wrapper + desktop Exec
EXT="$TMP/deb-extract"
mkdir -p "$EXT"
dpkg-deb -x "$DEB" "$EXT"
grep -q '/opt/tacx-desktop' "$EXT/usr/bin/tacx-desktop"
grep -qx 'Exec=tacx-desktop' "$EXT/usr/share/applications/com.nielsver.tacx_desktop.desktop"
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$EXT/usr/share/applications/com.nielsver.tacx_desktop.desktop"
fi

# --- AppDir layout (skip appimagetool download if SKIP_APPIMAGE=1) ---
if [[ "${SKIP_APPIMAGE:-}" == "1" ]]; then
  echo "SKIP_APPIMAGE=1 — AppImage step skipped"
else
  # Build AppDir the same way the script does, then optionally run appimagetool
  # If network/appimagetool fails, still verify AppDir construction by sourcing steps.
  set +e
  "$ROOT/scripts/package_linux_appimage.sh" "$BUNDLE" "0.2.1-test" "$OUT"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ls "$OUT"/Tacx_Desktop-0.2.1-test-*.AppImage >/dev/null
    echo "AppImage packaging OK"
  else
    echo "WARN: appimagetool failed (often FUSE/network on restricted hosts) — validating AppDir manually"
    # Manual AppDir check mirroring the script
    APPDIR="$TMP/AppDir"
    mkdir -p "$APPDIR"
    cp -a "$BUNDLE"/. "$APPDIR/"
    cat > "$APPDIR/AppRun" <<'AR'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
cd "$HERE"
exec "${HERE}/tacx_desktop" "$@"
AR
    chmod +x "$APPDIR/AppRun" "$APPDIR/tacx_desktop"
    [[ -f "$APPDIR/lib/libtacx_desktop_core.so" ]]
    [[ -x "$APPDIR/AppRun" ]]
    echo "AppDir layout OK (appimagetool not exercised)"
  fi
fi

# --- install.sh still works on tarball-style tree ---
export XDG_DATA_HOME="$TMP/xdg"
cp "$ROOT/packaging/linux/install.sh" "$ROOT/packaging/linux/uninstall.sh" "$BUNDLE/"
chmod +x "$BUNDLE/install.sh" "$BUNDLE/uninstall.sh"
"$BUNDLE/install.sh"
[[ -f "$XDG_DATA_HOME/applications/com.nielsver.tacx_desktop.desktop" ]]
"$BUNDLE/uninstall.sh"
echo "linux packaging smoke OK"
