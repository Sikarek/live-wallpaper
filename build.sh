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

# Install (or repair) the per-user LaunchAgent. A silently failed bootstrap is the difference between
# a wallpaper that comes back after a reboot and one that never returns, so this verifies it.
install_launch_agent() {
  local plist="$1"
  local label
  label="$(basename "$plist" .plist)"
  plutil -lint "$plist" >/dev/null || { echo "    INVALID plist: $plist"; return 1; }
  launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  local attempt
  for attempt in 1 2 3 4 5; do          # bootstrap can fail with EIO right after a bootout
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break
    sleep 1
  done
  launchctl kickstart "gui/$(id -u)/$label" 2>/dev/null || true
  # spawning can be throttled after a crash loop; poll instead of a fixed sleep
  local waited=0
  while [ "$waited" -lt 15 ]; do
    if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q "state = running"; then
      echo "    login agent: loaded and running ($plist)"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # one more kick, then a final check
  launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || true
  sleep 3
  if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q "state = running"; then
    echo "    login agent: loaded and running after a retry ($plist)"
    return 0
  fi
  echo "    WARNING: the login agent is NOT running — the wallpaper would not survive a reboot."
  echo "             retry:  launchctl bootstrap gui/$(id -u) \"$plist\""
  return 1
}

echo "==> building $APP_NAME $VERSION"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$BUILD_DIR"

APP_SOURCES="Sources/main.swift Sources/WallpaperModel.swift Sources/WallpaperHost.swift Sources/UI.swift Sources/SelfTest.swift"
swiftc -O -o "$MACOS_DIR/$APP_NAME" $APP_SOURCES
echo "    app binary: $(ls -l "$MACOS_DIR/$APP_NAME" | awk '{print $5}') bytes"

# helper: image -> looping MP4 (used by the video route)
swiftc -O -o "$BUILD_DIR/mkloop" tools/mkloop.swift
echo "    helper: build/mkloop"

# the CoreGraphics compositor (also bundled into the Composer app)
swiftc -O -o "$BUILD_DIR/composite_pngs" tools/composite_pngs.swift
echo "    helper: build/composite_pngs"

# Lock Screen tooling: render the scene to a looping video, inspect video files
swiftc -O -o "$BUILD_DIR/rendertitle" tools/rendertitle.swift
swiftc -O -o "$BUILD_DIR/probe_video" tools/probe_video.swift
echo "    tools: build/rendertitle, build/probe_video"

# the CLI variant: same engine, no menu bar — handy for scripting and for testing
swiftc -O -o "$BUILD_DIR/wphost" Sources/wphost-cli.swift
echo "    cli: build/wphost"

# post the app's distributed notifications from a script (the Composer does this itself after export)
swiftc -O -o "$BUILD_DIR/lwpost" tools/lwpost.swift
echo "    helper: build/lwpost"

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

# ------------------------------------------------------------------------------------------------
# Starbound Composer — a second, independent app: choose a combination of the game's own celestial art,
# see it live, and export it into the wallpaper library. It bundles tools/starbound_mainmenu.py and
# drives it, so the preview and the exported wallpaper come from one renderer (no second implementation
# to drift out of sync), and the combo palette always matches the tool that draws it.
# ------------------------------------------------------------------------------------------------
COMPOSER_NAME="StarboundComposer"
COMPOSER_BUNDLE_ID="com.sikarek.starbound-composer"
COMPOSER_VERSION="1.0"
COMPOSER_APP="$BUILD_DIR/$COMPOSER_NAME.app"
COMPOSER_MACOS="$COMPOSER_APP/Contents/MacOS"
COMPOSER_RESOURCES="$COMPOSER_APP/Contents/Resources/tools"

echo "==> building $COMPOSER_NAME $COMPOSER_VERSION"
rm -rf "$COMPOSER_APP"
mkdir -p "$COMPOSER_MACOS" "$COMPOSER_RESOURCES"
swiftc -O -o "$COMPOSER_MACOS/$COMPOSER_NAME" \
  Sources/composer/main.swift \
  Sources/composer/ComposerModel.swift \
  Sources/composer/ComposerPreview.swift \
  Sources/composer/ComposerUI.swift \
  Sources/composer/ComposerSelfTest.swift
echo "    app binary: $(ls -l "$COMPOSER_MACOS/$COMPOSER_NAME" | awk '{print $5}') bytes"
cp -f tools/starbound_mainmenu.py tools/starbound_unpack.py "$COMPOSER_RESOURCES/"
cp -f "$BUILD_DIR/composite_pngs" "$COMPOSER_RESOURCES/"       # prebuilt: nothing is compiled at runtime
echo "    bundled tools: $(ls "$COMPOSER_RESOURCES" | tr '\n' ' ')"

cat > "$COMPOSER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>CFBundleName</key>                     <string>$COMPOSER_NAME</string>
        <key>CFBundleDisplayName</key>              <string>Starbound Composer</string>
        <key>CFBundleIdentifier</key>               <string>$COMPOSER_BUNDLE_ID</string>
        <key>CFBundleExecutable</key>               <string>$COMPOSER_NAME</string>
        <key>CFBundlePackageType</key>              <string>APPL</string>
        <key>CFBundleShortVersionString</key>       <string>$COMPOSER_VERSION</string>
        <key>CFBundleVersion</key>                  <string>$COMPOSER_VERSION</string>
        <key>LSMinimumSystemVersion</key>           <string>13.0</string>
        <key>NSHighResolutionCapable</key>          <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$COMPOSER_APP/Contents/PkgInfo"

echo "==> signing $COMPOSER_NAME"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$COMPOSER_APP" 2>&1 | sed 's/^/    /'
else
  codesign --force --sign - --timestamp=none "$COMPOSER_APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$COMPOSER_APP" 2>&1 | sed 's/^/    /' || true
echo "==> done: $COMPOSER_APP"

if [ "${1:-}" = "--install" ]; then
  DEST="${2:-$HOME/Applications}"
  mkdir -p "$DEST"
  rm -rf "$DEST/$COMPOSER_NAME.app"
  cp -R "$COMPOSER_APP" "$DEST/"
  cp -f support/StarboundComposer.command "$DEST/" && chmod +x "$DEST/StarboundComposer.command"
  echo "==> installed: $DEST/$COMPOSER_NAME.app"
  echo "    also:      $DEST/StarboundComposer.command  (double-click this if the .app refuses to open)"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/$COMPOSER_NAME.app" >/dev/null 2>&1 || true
fi

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
  # Only ONE thing may start the app: launchd. Starting it with `open` as well put two instances in
  # a race — the extra one hits the single-instance guard, exits immediately, and launchd reads those
  # immediate exits as a crash loop and throttles the job (which is why the wallpaper stopped coming
  # back after sleep). So: install the agent, kickstart it, and do not launch anything by hand.
  PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # every placeholder must be substituted: launchd refuses to spawn a job whose log path does not
  # exist, which showed up as 'state = spawn scheduled' forever
  sed "s|__APP__|$DEST/$APP_NAME.app|g; s|__BUNDLE_ID__|$BUNDLE_ID|g; s|__LOG__|$HOME/Library/Logs/$APP_NAME.log|g" \
      support/launchagent.plist > "$PLIST"
  if grep -q "__" "$PLIST"; then
    echo "    ERROR: unsubstituted placeholder left in $PLIST:"; grep -n "__" "$PLIST" | sed 's/^/      /'
  fi
  install_launch_agent "$PLIST" || true
  echo "==> running through launchd; the sparkles icon is in the menu bar (starts at login, restarts if killed)"
fi
