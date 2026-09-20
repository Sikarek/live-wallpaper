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
import tempfile
import time

HOME = os.path.expanduser("~")
STORE = f"{HOME}/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
VIDEOS = f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/videos"
THUMBS = f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/thumbnails"
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


def decoder_running():
    """Is the system actually decoding the selected aerial? A live coremedia.videodecoder means the
    wallpaper extension accepted our file and is playing it; no decoder means it did not."""
    out = subprocess.run(["pgrep", "-fl", "coremedia.videodecoder"], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if "wallpaper" in l.lower() or "aerials" in l.lower()]


def verify():
    asset = selected_asset()
    if not asset:
        print("no aerial selected")
        return False
    slot, backup = slot_for(asset), backup_for(asset)
    ok = True
    print(f"selected aerial : {asset}")
    if not os.path.exists(slot):
        print("  slot file missing"); return False
    ours = os.path.exists(backup) and os.path.getsize(slot) != os.path.getsize(backup)
    print(f"  slot holds    : {'YOUR video' if ours else 'Apple original'}")
    info = probe(slot)
    for line in info.splitlines():
        print(f"  {line}")
    # the system's own encoding for this asset is branded url-4K-SDR-240FPS: 4K, SDR, 240 fps, 10 bit
    import re
    fps = re.search(r"([\d.]+) fps", info)
    depth = re.search(r"bit depth=(\d+)", info)
    size = re.search(r"(\d+)x(\d+)", info)
    if fps and float(fps.group(1)) < 200:
        print(f"  WARNING: {fps.group(1)} fps — the system expects ~240 fps for an aerial")
        ok = False
    if depth and depth.group(1) != "10":
        print(f"  WARNING: {depth.group(1)}-bit — Apple's aerials are 10-bit")
        ok = False
    if size and (int(size.group(1)) < 3840):
        print(f"  note: {size.group(0)} — Apple serves these at 4K (the system will scale yours)")
    decoders = decoder_running()
    print(f"  decoder process: {'yes' if decoders else 'not running'}"
          f"{' — the extension is playing the slot' if decoders else ' — lock the screen to start it'}")
    return ok


def diagnose():
    """Everything the system's aerial extension says about the slot, plus the format check."""
    verify()
    print("\n  --- what the wallpaper extension logged (last 5 min) ---")
    out = subprocess.run(["log", "show", "--last", "5m",
                          "--predicate", 'process CONTAINS "Wallpaper"',
                          "--style", "compact"], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines()
             if any(k in l for k in ("enqueued", "error", "Error", "fail", "Fail", "asset", "Asset"))]
    if not lines:
        print("    nothing (the extension is silent — normal while your desktop window covers it)")
    for line in lines[-12:]:
        print("    " + line[:180])
    print("\n  note: 'wallpaper video paused while the desktop is covered' is normal: macOS stops the")
    print("        aerial's frames when nothing can see it. Frames should be enqueued on the lock screen.")


def reapply():
    """Nudge the system into rebuilding its cached view of the slot."""
    asset = selected_asset()
    if not asset:
        sys.exit("no aerial selected")
    slot = slot_for(asset)
    if os.path.exists(slot):
        os.utime(slot, None)                      # the extension keys its cache on the file's mtime
        print(f"  touched {slot}")
    restart_wallpaper_agent()
    time.sleep(2)
    decoders = decoder_running()
    print(f"  decoder process after reload: {'yes' if decoders else 'not yet (appears when the lock screen or desktop draws)'}")


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


def swap_thumbnail(asset, video):
    """The asset's still (shown in Settings, and before motion starts) is a PNG next to the videos.
    Replace it with a frame of our clip, keeping Apple's original in the backup folder."""
    thumb = os.path.join(THUMBS, f"{asset}.png")
    if not os.path.exists(thumb):
        print("  no thumbnail for this asset — nothing to swap")
        return
    os.makedirs(BACKUP, exist_ok=True)
    saved = os.path.join(BACKUP, f"{asset}.thumb.png")
    if not os.path.exists(saved):
        shutil.copy2(thumb, saved)
        print(f"  backed up Apple's still -> {saved}")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["qlmanage", "-t", "-s", "214", "-o", tmp, video],
                       capture_output=True)
        produced = [os.path.join(tmp, f) for f in os.listdir(tmp)]
        if not produced:
            print("  could not render a still from the video; left Apple's")
            return
        shutil.copy2(produced[0], thumb)
        os.chmod(thumb, 0o600)
        print(f"  replaced the asset's still with a frame of your video ({os.path.getsize(thumb)} bytes)")


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
    swap_thumbnail(asset, slot)
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
    saved = os.path.join(BACKUP, f"{asset}.thumb.png")
    thumb = os.path.join(THUMBS, f"{asset}.png")
    if os.path.exists(saved):
        shutil.copy2(saved, thumb)
        os.chmod(thumb, 0o600)
        print(f"  restored Apple's still -> {thumb}")
    restart_wallpaper_agent()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--status", action="store_true", help="show the selected aerial and slot contents")
    group.add_argument("--install", metavar="VIDEO", help="take the lock-screen slot with this video")
    group.add_argument("--restore", action="store_true", help="put Apple's original video back")
    group.add_argument("--verify", action="store_true",
                       help="check the slot: format vs Apple's, and whether the system is decoding it")
    group.add_argument("--reapply", action="store_true",
                       help="nudge the system to rebuild its cached view of the slot")
    group.add_argument("--diagnose", action="store_true",
                       help="verify + dump what the system's wallpaper extension logged")
    args = ap.parse_args()

    if args.status:
        status()
    elif args.install:
        install(os.path.expanduser(args.install))
    elif args.restore:
        restore()
    elif args.verify:
        sys.exit(0 if verify() else 1)
    elif args.reapply:
        reapply()
    elif args.diagnose:
        diagnose()


if __name__ == "__main__":
    main()
