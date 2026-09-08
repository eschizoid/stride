#!/usr/bin/env bash
# Builds the Form Board as a real macOS app: ~/Applications/Stride Form Board.app,
# launchable from Launchpad/Spotlight/Dock like anything else. The bundle carries
# its own binary (no roc needed at launch); the stride logo becomes the icon.
#
# The launcher widens PATH before exec: a GUI app inherits launchd's minimal
# PATH, and the board shells out to `stride` (CP fit) and `sh`/`printenv`.
set -euo pipefail
cd "$(dirname "$0")/.."

ROC_VIZ="${ROC_VIZ:-roc}"
APP="$HOME/Applications/Stride Form Board.app"
C="$APP/Contents"

echo "building the viz binary ($ROC_VIZ)..."
"$ROC_VIZ" build src/viz/main.roc --output=/tmp/stride-viz --opt=dev

mkdir -p "$C/MacOS" "$C/Resources"
cp /tmp/stride-viz "$C/MacOS/stride-viz"

cat > "$C/MacOS/launcher" <<'SH'
#!/bin/bash
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
cd "$HOME"
exec "$(dirname "$0")/stride-viz"
SH
chmod +x "$C/MacOS/launcher" "$C/MacOS/stride-viz"

cat > "$C/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Stride Form Board</string>
  <key>CFBundleDisplayName</key><string>Stride Form Board</string>
  <key>CFBundleIdentifier</key><string>com.eschizoid.stride.formboard</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>stride.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# icon: the repo logo, rendered at every size Launchpad wants
ICONSET=/tmp/stride.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s img/stride.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d img/stride.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/stride.icns"

# a fresh bundle can be quarantined or stale-cached; clear both
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
touch "$APP"
echo "installed: $APP"
echo "launch it from Launchpad/Spotlight as 'Stride Form Board'"
