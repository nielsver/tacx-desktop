#!/usr/bin/env bash
# Build a Tacx Desktop .deb from a Flutter Linux release bundle.
# Usage: ./scripts/package_linux_deb.sh [bundle_dir] [version] [outdir]
# Installs under /opt/tacx-desktop with a /usr/bin/tacx-desktop wrapper + desktop entry.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT/build/linux/x64/release/bundle}"
VERSION="${2:-}"
OUTDIR="${3:-$ROOT}"
APP_ID="com.nielsver.tacx_desktop"
PKG_NAME="tacx-desktop"
OPT_DIR="opt/tacx-desktop"

if [[ -z "$VERSION" ]]; then
  if [[ "${GITHUB_REF_TYPE:-}" == tag ]]; then
    VERSION="${GITHUB_REF_NAME#v}"
  else
    VERSION="0.2.1"
  fi
fi
# Debian version: tags like v0.2.1 → 0.2.1; local builds keep digits/dots/+~
VERSION="$(echo "$VERSION" | sed -E 's/^v//; s/[^0-9A-Za-z.+~-]/./g')"
[[ -n "$VERSION" ]] || VERSION="0.2.1"

[[ -d "$BUNDLE" ]] || { echo "Bundle missing: $BUNDLE" >&2; exit 1; }
[[ -f "$BUNDLE/tacx_desktop" ]] || { echo "Binary missing" >&2; exit 1; }
compgen -G "$BUNDLE/lib/*tacx_desktop_core*" >/dev/null \
  || { echo "libtacx_desktop_core missing" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb required" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROOTFS="$TMP/rootfs"
mkdir -p "$ROOTFS/DEBIAN" \
  "$ROOTFS/$OPT_DIR" \
  "$ROOTFS/usr/bin" \
  "$ROOTFS/usr/share/applications" \
  "$ROOTFS/usr/share/icons/hicolor/256x256/apps" \
  "$ROOTFS/usr/share/doc/$PKG_NAME"

cp -a "$BUNDLE"/. "$ROOTFS/$OPT_DIR/"
chmod +x "$ROOTFS/$OPT_DIR/tacx_desktop"
# Prefer packaged icon/first-run
cp -f "$ROOT/packaging/linux/$APP_ID.png" "$ROOTFS/$OPT_DIR/$APP_ID.png"
cp -f "$ROOT/packaging/linux/$APP_ID.png" \
  "$ROOTFS/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
cp -f "$ROOT/packaging/linux/FIRST_RUN.txt" "$ROOTFS/$OPT_DIR/FIRST_RUN.txt"
cp -f "$ROOT/packaging/linux/FIRST_RUN.txt" "$ROOTFS/usr/share/doc/$PKG_NAME/FIRST_RUN.txt"
gzip -9n -c "$ROOT/packaging/linux/FIRST_RUN.txt" > "$ROOTFS/usr/share/doc/$PKG_NAME/changelog.gz" 2>/dev/null \
  || printf 'tacx-desktop (%s) unstable; urgency=low\n\n  * Packaged release.\n\n -- Tacx Desktop <noreply@users.noreply.github.com>  %s\n' \
       "$VERSION" "$(date -R)" | gzip -9n > "$ROOTFS/usr/share/doc/$PKG_NAME/changelog.gz"
cat > "$ROOTFS/usr/share/doc/$PKG_NAME/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: tacx-desktop
Source: https://github.com/nielsver/tacx-desktop

Files: *
Copyright: Niels Vervoort and contributors
License: proprietary-or-see-repo
COPY

# Wrapper so PATH finds the app; cwd not required (RPATH + LD_LIBRARY_PATH).
cat > "$ROOTFS/usr/bin/tacx-desktop" <<'WRAP'
#!/bin/bash
set -euo pipefail
DIR="/opt/tacx-desktop"
export LD_LIBRARY_PATH="${DIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$DIR"
exec "$DIR/tacx_desktop" "$@"
WRAP
chmod +x "$ROOTFS/usr/bin/tacx-desktop"

cat > "$ROOTFS/usr/share/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.5
Name=Tacx Desktop
GenericName=Smart trainer control
Comment=Control a Tacx / FTMS smart trainer over Bluetooth (ERG, resistance, simulation)
Exec=tacx-desktop
Icon=$APP_ID
Terminal=false
Categories=Utility;
Keywords=tacx;trainer;ftms;fec;erg;bike;cycling;bluetooth;
StartupNotify=true
StartupWMClass=tacx_desktop
DESKTOP

# Installed-size in KiB
SIZE_KB="$(du -sk "$ROOTFS" | awk '{print $1}')"
# Subtract DEBIAN roughly
SIZE_KB=$((SIZE_KB > 20 ? SIZE_KB - 20 : SIZE_KB))

cat > "$ROOTFS/DEBIAN/control" <<CTRL
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $SIZE_KB
Maintainer: Niels Vervoort <noreply@users.noreply.github.com>
Depends: libgtk-3-0, libglib2.0-0, libepoxy0, zlib1g
Recommends: bluez, bluez-tools
Homepage: https://github.com/nielsver/tacx-desktop
Description: Desktop remote for Tacx / FTMS smart trainers
 Flutter + Rust BLE app for ERG, resistance, and simulation control
 of Tacx and Wahoo Kickr (public FTMS) trainers. Primary target:
 Garuda / Arch Linux with BlueZ. Do not run as root.
CTRL

cat > "$ROOTFS/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -q -t /usr/share/icons/hicolor 2>/dev/null || true
fi
echo "Tacx Desktop installed. Find it in the app menu, or run: tacx-desktop"
echo "BlueZ tip: enable bluetooth, join the bluetooth group, quit Zwift/Wahoo, leave trainer unpaired."
POST
chmod +x "$ROOTFS/DEBIAN/postinst"

cat > "$ROOTFS/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi
POSTRM
chmod +x "$ROOTFS/DEBIAN/postrm"

mkdir -p "$OUTDIR"
OUT_NAME="${PKG_NAME}_${VERSION}_amd64.deb"
OUT_PATH="$OUTDIR/$OUT_NAME"
rm -f "$OUT_PATH"
dpkg-deb --root-owner-group --build "$ROOTFS" "$OUT_PATH"
# Validate if possible
if command -v dpkg-deb >/dev/null; then
  dpkg-deb -I "$OUT_PATH" | head -20
fi
ls -lh "$OUT_PATH"
echo "DEB=$OUT_PATH"
