#!/usr/bin/env bash
# ============================================================================
# Linux release build for Embrace (AGPL) — single, self-contained script.
# Produces a portable AppImage with all NON-system dependencies + the app icon
# bundled. The Linux counterpart of tools/win-build.bat.
#
#   Output: temp/embrace-linux-x86_64.AppImage
#
# Prerequisites:
#   1. crystal + `shards install` already run.
#   2. ImageMagick (convert/identify), patchelf, file — for icon extraction and
#      the dependency-bundling that linuxdeploy performs.
#   3. Network access: linuxdeploy + appimagetool are downloaded on first run
#      (they are themselves AppImages).
#
# Everything this script produces lives under temp/ (gitignored), so a build
# leaves NOTHING behind in the working tree. This is the exact build the Release
# workflow (.github/workflows/release.yml) runs on a v* tag.
# ============================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

TEMP="temp"
APPDIR="$TEMP/AppDir"
ICO="resources/embrace-logo.ico"   # canonical app icon (square 16…256)

rm -rf "$APPDIR"
mkdir -p "$TEMP"

# linuxdeploy + appimagetool are AppImages; GitHub runners (ubuntu-24.04) ship no
# FUSE, so run them via their built-in extract-and-run path instead.
export APPIMAGE_EXTRACT_AND_RUN=1

# 1) Wire the vendored SFML 3 / CSFML 3 paths (LD_LIBRARY_PATH) so both the
#    linker and `ldd` (which linuxdeploy walks) resolve them.
# shellcheck source=/dev/null
source setup.sh

# 2) Build the release binary. NOT --static: the C/SFML deps are bundled into the
#    AppImage instead, and a fully static GUI binary is fragile on Linux anyway.
shards build embrace --release --no-debug

# 3) Fetch linuxdeploy (assembles the AppDir) + appimagetool (packs it). Cached
#    across local re-runs. linuxdeploy walks ldd, copies the dependency closure into
#    the AppDir, patches RPATHs, and honours the AppImage excludelist — so host
#    libraries (libGL, libX11, libxcb, the GL driver stack) are deliberately NOT
#    bundled.
fetch() { [ -f "$TEMP/$1" ] || wget -qO "$TEMP/$1" "$2"; chmod +x "$TEMP/$1"; }
fetch linuxdeploy  https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
fetch appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

# 4) Multi-size desktop icons, extracted from the .ico's matching frames
#    (no scaling/distortion — every standard size is already present).
for px in 16 24 32 48 64 128 256; do
    frame=$(identify -format '%p %w\n' "$ICO" | awk -v w="$px" '$2==w{print $1; exit}')
    [ -n "$frame" ] || continue
    dir="$APPDIR/usr/share/icons/hicolor/${px}x${px}/apps"
    mkdir -p "$dir"
    convert "${ICO}[$frame]" "$dir/embrace.png"
done
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/embrace.png" "$TEMP/embrace.png"

# 5) Assemble the AppDir (deps + RPATHs + AppRun + desktop/icon at the root).
"$TEMP/linuxdeploy" \
    --appdir "$APPDIR" \
    --executable bin/embrace \
    --desktop-file resources/embrace.desktop \
    --icon-file "$TEMP/embrace.png"

# linuxdeploy points the AppDir's root icon (→ appimagetool's .DirIcon, i.e. the
# file-manager thumbnail) at the 64x64 frame; repoint it at 256x256 so it stays crisp.
ln -sf usr/share/icons/hicolor/256x256/apps/embrace.png "$APPDIR/embrace.png"

# 6) Pack the AppImage under the stable, version-less name the website links
#    (/releases/latest/download/embrace-linux-x86_64.AppImage); the version stays
#    visible in the About dialog and the GitHub Release title.
"$TEMP/appimagetool" "$APPDIR" "$TEMP/embrace-linux-x86_64.AppImage"

echo "OK: temp/embrace-linux-x86_64.AppImage built ($(du -h "$TEMP/embrace-linux-x86_64.AppImage" | cut -f1))."
