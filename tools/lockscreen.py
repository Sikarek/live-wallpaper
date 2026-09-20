#!/usr/bin/env python3
"""
lockscreen.py — play your own video on the macOS Lock Screen.

Why this exists: macOS 26+ has **no API** for custom live lock-screen content. The lock screen (and
the login window at boot) is drawn by the system before your session exists, and the only animated
thing it will show is one of Apple's own "aerial" videos. Every app that claims lock-screen video
does the same thing this does: it replaces the video file of the *currently selected* aerial, so the
system plays your clip believing it is its own. Apple's original is backed up first and --restore
puts it back.

    python3 tools/lockscreen.py --status            # what is selected, and is the slot ours?
    python3 tools/lockscreen.py --install out.mov   # back up Apple's file, then take the slot
    python3 tools/lockscreen.py --restore           # put Apple's file back

Caveats worth knowing:
  * Re-pick a wallpaper / a macOS update can re-download the original, undoing this. Re-run --install.
  * The clip should be a .mov, no audio, HEVC or H.264. The system scales it to the display.
  * macOS plays the same asset on the desktop as well; the LiveWallpaper app draws over it, so you
    still get the interactive wallpaper after login.
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
STORE = f"{HOME}/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
VIDEOS = f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/videos"
BACKUP = f"{HOME}/Library/Application Support/LiveWallpaper/lockscreen-backup"
_here = os.path.dirname(os.path.abspath(__file__))
PROBE = next((c for c in (os.path.join(_here, "..", "build", "probe_video"),
                          os.path.join(_here, "probe_video")) if os.path.exists(c)), "")


def selected_asset():
    """The assetID of the aerial the system is currently using (or None)."""
    try:
        data = plistlib.loads(open(STORE, "rb").read())
    except Exception as error:
        sys.exit(f"cannot read {STORE}: {error}")

    found = []

    def walk(node):
        if isinstance(node, dict):
            provider = node.get("Provider")
            config = node.get("Configuration")
            if provider == "com.apple.wallpaper.choice.aerials" and isinstance(config, (bytes, bytearray)):
                try:
                    asset = plistlib.loads(bytes(config)).get("assetID")
                except Exception:
                    asset = None
                if asset:
                    found.append(asset)
            for key, value in node.items():
                if key != "Configuration":
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    return found[0] if found else None


def slot_for(asset):
    return os.path.join(VIDEOS, f"{asset}.mov")


def backup_for(asset):
    return os.path.join(BACKUP, f"{asset}.mov")


def human(path):
    if not os.path.exists(path):
        return "missing"
    return f"{os.path.getsize(path) / 1_000_000:.1f} MB, modified {os.path.getmtime(path):.0f}"


def probe(path):
    if os.path.exists(PROBE) and os.path.exists(path):
        result = subprocess.run([PROBE, path], capture_output=True, text=True)
        return result.stdout.strip()
    return ""


def restart_wallpaper_agent():
    for name in ("Wallpaper", "WallpaperAgent", "WallpaperVideoExtension"):
        subprocess.run(["killall", name], capture_output=True)
    print("  asked the wallpaper agent to reload (it respawns automatically)")


def status():
    asset = selected_asset()
    print(f"selected aerial : {asset or 'none (System Settings has no aerial picked)'}")
    if not asset:
        print("  pick any aerial in System Settings > Wallpaper once: that creates the slot to use.")
        return
    slot, backup = slot_for(asset), backup_for(asset)
    print(f"slot            : {slot}")
    print(f"  current file  : {human(slot)}")
    print(f"  apple backup  : {human(backup)}")
    if os.path.exists(slot) and os.path.exists(backup):
        same = os.path.getsize(slot) == os.path.getsize(backup)
        state = "Apple's original" if same else "YOUR video"
        print(f"  slot holds    : {state}")


def install(video):
    if not os.path.exists(video):
        sys.exit(f"no such video: {video}")
    asset = selected_asset()
    if not asset:
        sys.exit("no aerial is selected. Pick any aerial in System Settings > Wallpaper first, "
                 "then re-run --install (that is the slot the lock screen plays).")
    slot = slot_for(asset)
    if not os.path.exists(slot):
        sys.exit(f"the selected aerial has no downloaded video at {slot}\n"
                 "  open System Settings > Wallpaper and make sure that aerial is downloaded.")

    info = probe(video)
    if "codec=" not in info and PROBE and os.path.exists(PROBE):
        sys.exit(f"that file has no video track:\n{info}")

    os.makedirs(BACKUP, exist_ok=True)
    backup = backup_for(asset)
    if not os.path.exists(backup):
        shutil.copy2(slot, backup)
        print(f"  backed up Apple's original -> {backup} ({os.path.getsize(backup)/1_000_000:.1f} MB)")
    else:
        print(f"  Apple's original already backed up -> {backup}")

    shutil.copy2(video, slot)
    os.chmod(slot, 0o600)                       # Apple's own files are 0600
    print(f"  installed {video} -> {slot} ({os.path.getsize(slot)/1_000_000:.1f} MB)")
    restart_wallpaper_agent()
    print("\n  Lock the screen (Control-Command-Q) to see it. The login window at boot uses the same slot.")


def restore():
    asset = selected_asset()
    if not asset:
        sys.exit("no aerial selected; nothing to restore")
    slot, backup = slot_for(asset), backup_for(asset)
    if not os.path.exists(backup):
        sys.exit(f"no backup for {asset} — nothing to restore")
    shutil.copy2(backup, slot)
    os.chmod(slot, 0o600)
    print(f"  restored Apple's original -> {slot}")
    restart_wallpaper_agent()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--status", action="store_true", help="show the selected aerial and slot contents")
    group.add_argument("--install", metavar="VIDEO", help="take the lock-screen slot with this video")
    group.add_argument("--restore", action="store_true", help="put Apple's original video back")
    args = ap.parse_args()

    if args.status:
        status()
    elif args.install:
        install(os.path.expanduser(args.install))
    elif args.restore:
        restore()


if __name__ == "__main__":
    main()
