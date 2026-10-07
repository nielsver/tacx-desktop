#!/usr/bin/env bash
# Build a Tacx Desktop AppImage from a Flutter Linux release bundle.
# Usage: ./scripts/package_linux_appimage.sh [bundle_dir] [version] [outdir]
# Designed for GitHub Actions ubuntu runners (downloads appimagetool if needed).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT/build/linux/x64/release/bundle}"
VERSION="${2:-}"
OUTDIR="${3:-$ROOT}"
APP_ID="com.nielsver.tacx_desktop"
APP_NAME="Tacx Desktop"
BIN_NAME="tacx_desktop"

# appimagetool needs `file` (libmagic) on PATH
if ! command -v file >/dev/null 2>&1; then
  echo "Install 'file' (libmagic) before building an AppImage: sudo apt-get install -y file" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  if [[ "${GITHUB_REF_TYPE:-}" == tag ]]; then
    VERSION="${GITHUB_REF_NAME}"
  else
    VERSION="0.2.1-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
  fi
fi
# AppImage arch tag
ARCH="${APPIMAGE_ARCH:-x86_64}"

[[ -d "$BUNDLE" ]] || { echo "Bundle missing: $BUNDLE" >&2; exit 1; }
[[ -f "$BUNDLE/$BIN_NAME" ]] || { echo "Binary missing: $BUNDLE/$BIN_NAME" >&2; exit 1; }
compgen -G "$BUNDLE/lib/*tacx_desktop_core*" >/dev/null \
  || { echo "libtacx_desktop_core missing under $BUNDLE/lib" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APPDIR="$TMP/AppDir"
mkdir -p "$APPDIR"

# Flutter bundle at AppDir root so $ORIGIN/lib RPATH keeps working.
cp -a "$BUNDLE"/. "$APPDIR/"
# Packaging extras (icon / first-run) if not already copied into the bundle.
ICON_SRC="$ROOT/packaging/linux/$APP_ID.png"
[[ -f "$APPDIR/$APP_ID.png" ]] || cp "$ICON_SRC" "$APPDIR/$APP_ID.png"
[[ -f "$APPDIR/FIRST_RUN.txt" ]] || cp "$ROOT/packaging/linux/FIRST_RUN.txt" "$APPDIR/FIRST_RUN.txt" 2>/dev/null || true
chmod +x "$APPDIR/$BIN_NAME"

# Desktop entry (Exec/Icon basenames — appimagetool rewrites Exec for AppRun).
cat > "$APPDIR/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.5
Name=$APP_NAME
GenericName=Smart trainer control
Comment=Control a Tacx / FTMS smart trainer over Bluetooth (ERG, resistance, simulation)
Exec=$BIN_NAME
Icon=$APP_ID
Terminal=false
Categories=Utility;
Keywords=tacx;trainer;ftms;fec;erg;bike;cycling;bluetooth;
StartupNotify=true
StartupWMClass=$BIN_NAME
X-AppImage-Version=$VERSION
DESKTOP

# AppRun: stay in AppDir so RPATH \$ORIGIN/lib resolves the Rust cdylib.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${0}")")"
cd "$HERE"
export LD_LIBRARY_PATH="${HERE}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Wayland blank/crash escape hatch for some Plasma setups:
#   GDK_BACKEND=x11 ./Tacx_Desktop-*.AppImage
exec "${HERE}/tacx_desktop" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# appimagetool expects Icon=<name> and <name>.png in AppDir.
cp -f "$APPDIR/$APP_ID.png" "$APPDIR/.DirIcon" 2>/dev/null || true

# Locate or download appimagetool
TOOL="${APPIMAGETOOL:-}"
if [[ -z "$TOOL" || ! -x "$TOOL" ]]; then
  if command -v appimagetool >/dev/null 2>&1; then
    TOOL="$(command -v appimagetool)"
  else
    TOOL_DIR="$TMP/tools"
    mkdir -p "$TOOL_DIR"
    TOOL="$TOOL_DIR/appimagetool"
    URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
    echo "Downloading appimagetool from $URL"
    curl -fsSL -o "$TOOL" "$URL"
    chmod +x "$TOOL"
    # Extract if FUSE unavailable (common on CI)
    if ! "$TOOL" --appimage-help >/dev/null 2>&1; then
      (cd "$TOOL_DIR" && "$TOOL" --appimage-extract >/dev/null 2>&1) || true
      if [[ -x "$TOOL_DIR/squashfs-root/AppRun" ]]; then
        TOOL="$TOOL_DIR/squashfs-root/AppRun"
      fi
    fi
  fi
fi

mkdir -p "$OUTDIR"
OUT_NAME="Tacx_Desktop-${VERSION}-${ARCH}.AppImage"
OUT_PATH="$OUTDIR/$OUT_NAME"
rm -f "$OUT_PATH"

export ARCH
# ARCHITECTURE for older appimagetool
export ARCHITECTURE="$ARCH"
if ! "$TOOL" "$APPDIR" "$OUT_PATH"; then
  # Fallback: run extracted tool with --no-appstream
  "$TOOL" --no-appstream "$APPDIR" "$OUT_PATH"
fi

chmod +x "$OUT_PATH"
ls -lh "$OUT_PATH"
echo "APPIMAGE=$OUT_PATH"
