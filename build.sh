#!/usr/bin/env bash
# build.sh — compile LiveWallpaper into a real .app bundle and (optionally) install it.
#
#   ./build.sh                 -> build/LiveWallpaper.app
#   ./build.sh --install       -> also copy to ~/Applications and launch it
#
# Needs only the Command Line Tools (swiftc). No Xcode project, no Apple Developer account:
# the bundle is signed ad-hoc, which is enough to run it on your own Mac. If you ever want to
# hand the .app to someone else you need a Developer ID certificate + notarization.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LiveWallpaper"
BUNDLE_ID="com.sikarek.livewallpaper"      # change to whatever you like
VERSION="1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"

command -v swiftc >/dev/null || { echo "swiftc not found — install the Xcode Command Line Tools: xcode-select --install"; exit 1; }

echo "==> building $APP_NAME $VERSION"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$BUILD_DIR"

swiftc -O -o "$MACOS_DIR/$APP_NAME" Sources/LiveWallpaper.swift
echo "    app binary: $(ls -l "$MACOS_DIR/$APP_NAME" | awk '{print $5}') bytes"

# helper: image -> looping MP4 (used by the video route)
swiftc -O -o "$BUILD_DIR/mkloop" tools/mkloop.swift
echo "    helper: build/mkloop"

# the CLI variant: same engine, no menu bar — handy for scripting and for testing
swiftc -O -o "$BUILD_DIR/wphost" Sources/wphost-cli.swift
echo "    cli: build/wphost"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>CFBundleName</key>                     <string>$APP_NAME</string>
        <key>CFBundleDisplayName</key>              <string>$APP_NAME</string>
        <key>CFBundleIdentifier</key>               <string>$BUNDLE_ID</string>
        <key>CFBundleExecutable</key>               <string>$APP_NAME</string>
        <key>CFBundlePackageType</key>              <string>APPL</string>
        <key>CFBundleShortVersionString</key>       <string>$VERSION</string>
        <key>CFBundleVersion</key>                  <string>$VERSION</string>
        <key>LSMinimumSystemVersion</key>           <string>13.0</string>
        <key>LSUIElement</key>                      <true/>
        <key>NSHighResolutionCapable</key>          <true/>
        <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing"
# Ad-hoc signing is enough to run the app on the machine that built it (Gatekeeper reports "rejected"
# for any non-notarized bundle, but local apps still launch). A real identity is only needed to hand
# the .app to someone else — set LW_SIGN_IDENTITY="Developer ID Application: ..." to use one.
SIGN_ID="${LW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"/{print $2; exit}')}"
if [ -n "${SIGN_ID:-}" ]; then
  printf '    identity: %s\n' "$SIGN_ID"
  codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP" 2>&1 | sed 's/^/    /'
else
  codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
  printf '    ad-hoc signature (no code-signing identity in your keychain) — fine for your own Mac.\n'
  printf '    Distributing this bundle to other people needs a Developer ID + notarization.\n'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> done: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="${2:-$HOME/Applications}"
  mkdir -p "$DEST"
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  # Finder cannot open the ad-hoc signed bundle on macOS 26+, so ship the shell launcher too.
  cp -f support/LiveWallpaper.command "$DEST/" && chmod +x "$DEST/LiveWallpaper.command"
  echo "==> installed: $DEST/$APP_NAME.app"
  echo "    also:      $DEST/LiveWallpaper.command  (double-click this if the .app refuses to open)"
  echo "    (keep it in a stable folder — 'Start at Login' registers this path)"
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Register the fresh bundle before launching it: a bundle that LaunchServices has never seen
  # fails `open` with -10825 too.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/$APP_NAME.app" >/dev/null 2>&1 || true
  sleep 1
  # `open` can fail in non-GUI shells; launchd is the reliable way to start a menu-bar app
  if ! open "$DEST/$APP_NAME.app" 2>/dev/null; then
    PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__APP__|$DEST/$APP_NAME.app|g; s|__BUNDLE_ID__|$BUNDLE_ID|g" \
        support/launchagent.plist > "$PLIST"
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && echo "    started via launchd ($PLIST)" || true
  fi
  echo "==> launched; look for the sparkles icon in the menu bar"
fi
