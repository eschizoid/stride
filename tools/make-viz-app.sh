#!/usr/bin/env bash
# Builds the viz window as a real macOS app under $VIZ_APP_DIR (default
# ~/Applications),
# launchable from Launchpad/Spotlight/Dock like anything else. The bundle carries
# its own binary (no roc needed at launch); the stride logo becomes the icon.
#
# The launcher widens PATH before exec: a GUI app inherits launchd's minimal
# PATH, and the board shells out to `stride` (CP fit) and `sh`/`printenv`.
set -euo pipefail
cd "$(dirname "$0")/.."

# sips, iconutil and .app bundles are macOS-only — say so instead of failing
# three commands deep with a cryptic missing-tool error
[ "$(uname)" = Darwin ] || { echo "make-viz-app: macOS only (needs sips/iconutil and an .app bundle target)" >&2; exit 1; }

WORK=$(mktemp -d /tmp/stride-viz-app.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ROC_VIZ="${ROC_VIZ:-roc}"
APP_DIR="${VIZ_APP_DIR:-$HOME/Applications}"
mkdir -p "$APP_DIR"
APP="$APP_DIR/Stride.app"
C="$APP/Contents"

echo "building the viz binary ($ROC_VIZ)..."
"$ROC_VIZ" build src/viz/main.roc --output="$WORK/stride-viz" --opt=dev

mkdir -p "$C/MacOS" "$C/Resources"
cp "$WORK/stride-viz" "$C/MacOS/stride-viz"

cat > "$C/MacOS/launcher" <<'SH'
#!/bin/bash
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# the window reads ~/.stride/fonts; a downloaded bundle carries its own
# copies and seeds them here, or the window falls back to its default font
here="$(cd "$(dirname "$0")" && pwd)"
res="$here/../Resources"
log="$HOME/.stride/fonts-seed.log"
if [ -d "$res/fonts" ]; then
  if mkdir -p "$HOME/.stride/fonts" 2>/dev/null; then
    for f in "$res"/fonts/*.ttf; do
      [ -e "$f" ] || continue
      dst="$HOME/.stride/fonts/$(basename "$f")"
      # size, not existence: a short file from an interrupted copy would
      # otherwise be skipped forever
      if [ ! -e "$dst" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$dst")" ]; then
        cp "$f" "$dst" 2>>"$log" || echo "$(date): could not write $dst" >> "$log"
      fi
    done
  else
    echo "$(date): could not create $HOME/.stride/fonts - the window will use its fallback font" >> "$log" 2>/dev/null || true
  fi
fi
cd "$HOME"
exec "$here/stride-viz"
SH
chmod +x "$C/MacOS/launcher" "$C/MacOS/stride-viz"

# release-please maintains this marker; a second number would drift
VERSION=$(sed -n 's/^version = "stride \(.*\)".*/\1/p' src/main.roc | head -1)
[ -n "$VERSION" ] || VERSION="0.0.0-dev"

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Stride</string>
  <key>CFBundleDisplayName</key><string>Stride</string>
  <key>CFBundleIdentifier</key><string>com.eschizoid.stride.app</string>
  <key>CFBundleVersion</key><string>__VERSION__</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>stride</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$C/Info.plist"

# icon: the symbol badge, not the banner - a wordmark does not survive 16px
ICONSET="$WORK/stride.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s img/stride-icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d img/stride-icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/stride.icns"

# the window reads assets/fonts (cwd) or ~/.stride/fonts; the bundle carries
# copies for the launcher to seed, and this machine gets them for a repo-less
# launch. Missing files mean the default font.
mkdir -p "$C/Resources/fonts"
cp assets/fonts/*.ttf "$C/Resources/fonts/" 2>/dev/null || true
mkdir -p "$HOME/.stride/fonts"
cp assets/fonts/*.ttf "$HOME/.stride/fonts/" 2>/dev/null || true

# Apple Silicon refuses to exec an unsigned arm64 Mach-O, quarantine cleared
# or not. Ad-hoc needs no Developer ID; the launcher is a script and needs
# no signature.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$C/MacOS/stride-viz" 2>/dev/null || echo "warning: could not ad-hoc sign the binary"
fi

# clear any quarantine flag (absent on a local build, harmless either way)
# and bump mtime so Launch Services re-reads the bundle
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
touch "$APP"
echo "installed: $APP"
echo "launch it from Launchpad/Spotlight as 'Stride'"
if [ -d "$APP_DIR/Stride Form Board.app" ]; then
  echo "note: the old 'Stride Form Board.app' is still in $APP_DIR - delete it to keep one entry in Launchpad"
fi
