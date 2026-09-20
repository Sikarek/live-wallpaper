#!/bin/bash
# LiveWallpaper.command — double-click this file in Finder to start LiveWallpaper.
#
# WHY THIS EXISTS
# Convenience fallback for shells that cannot talk to LaunchServices (ssh sessions, agent shells),
# where `open LiveWallpaper.app` is unavailable. It starts the app binary directly — the same thing
# the LaunchAgent does — and prints the pid plus the stop/restart commands.

set -u
APP="${LIVEWALLPAPER_APP:-$HOME/Applications/LiveWallpaper.app}"
BIN="$APP/Contents/MacOS/LiveWallpaper"

if [ ! -x "$BIN" ]; then
  echo "LiveWallpaper is not installed at: $APP"
  echo
  echo "Build and install it first:"
  echo "    cd /path/to/live-wallpaper && ./build.sh --install"
  echo
  read -r -p "press return to close "
  exit 1
fi

if pgrep -x LiveWallpaper >/dev/null; then
  echo "LiveWallpaper is already running (pid $(pgrep -x LiveWallpaper | head -1))."
  echo "Its menu is on the sparkles icon in the menu bar."
  echo
  echo "Commands:"
  echo "    pkill -x LiveWallpaper        # stop the wallpaper"
  echo "    launchctl kickstart -k gui/\$(id -u)/com.sikarek.livewallpaper   # restart it"
  read -r -p "press return to close "
  exit 0
fi

nohup "$BIN" >/dev/null 2>&1 &
sleep 2

if pgrep -x LiveWallpaper >/dev/null; then
  echo "LiveWallpaper started (pid $(pgrep -x LiveWallpaper | head -1))."
  echo "Click the sparkles icon in the menu bar for wallpapers, Pause/Resume and Quit."
else
  echo "LiveWallpaper failed to start. Try running it in the foreground to see why:"
  echo "    \"$BIN\""
fi
sleep 1
