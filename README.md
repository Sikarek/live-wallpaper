# LiveWallpaper

A tiny native macOS live-wallpaper app. One borderless window per display, parked one level below
your desktop icons, playing whatever you point it at: an HTML/CSS/JS page, a looping video, or a
still image. Menu-bar only, always click-through, no Dock icon, no kernel extensions, no admin rights.

Written in ~380 lines of Swift. Builds with the **Command Line Tools alone** — no Xcode project, no
Apple Developer account, no notarization.

```
$ ./build.sh --install
==> building LiveWallpaper 1.0
    app binary: 141104 bytes
    helper: build/mkloop
    cli: build/wphost
==> ad-hoc signing
==> installed: /Users/you/Applications/LiveWallpaper.app
```

## How it works

macOS has no public API for animated wallpapers, so every app in this space does the same trick:

```
  level        0                 normal windows
              -2147483603        desktop icons      (kCGDesktopIconWindow)
   ours       -2147483604        <- LiveWallpaper's window
              -2147483623        desktop picture    (kCGDesktopWindow)
```

A borderless `NSWindow` at `kCGDesktopIconWindow - 1`, `ignoresMouseEvents = true` so the desktop
stays usable, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`
so it follows Spaces and stays out of Mission Control, and `NSApp.setActivationPolicy(.accessory)`
so there is no Dock icon. Making a video animate on the **Lock Screen** requires registering it into
Apple's aerial store (macOS 26+ only) — deliberately not done here.

## Install

```bash
git clone https://github.com/<you>/live-wallpaper.git
cd live-wallpaper
./build.sh --install          # -> ~/Applications/LiveWallpaper.app, then launches it
```

A sparkles icon appears in the menu bar: wallpaper list, Pause / Resume, Reload (⌘R),
Open Wallpapers Folder, Start at Login, Quit.

### Starting it from a shell that has no GUI session

`open App.app` can fail (`LaunchServices error -10825`) in ssh/agent shells. The reliable route is a
LaunchAgent, which also brings it back at login:

```bash
sed "s|__APP__|$HOME/Applications/LiveWallpaper.app|g; \
     s|__BUNDLE_ID__|com.sikarek.livewallpaper|g; \
     s|__LOG__|$HOME/Library/Logs/LiveWallpaper.log|g" \
  support/launchagent.plist > ~/Library/LaunchAgents/com.sikarek.livewallpaper.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sikarek.livewallpaper.plist
# remove it again:
launchctl bootout gui/$(id -u)/com.sikarek.livewallpaper
```

The in-app **Start at Login** toggle (`SMAppService`) does the same thing from the GUI; a
single-instance guard stops the two from stacking.

## Wallpapers

The app scans `~/Library/Application Support/LiveWallpaper/wallpapers/`. A wallpaper is either

| shape | example |
|---|---|
| a folder with `index.html` | any CSS/canvas animation; an `assets/` folder next to it is readable |
| a folder with one media file | `wallpapers/nebula/loop.mp4` |
| a loose file in `wallpapers/` | `wallpapers/stars.html`, `wallpapers/beach.mp4`, `wallpapers/space.jpg` |

- **video** `.mp4 .mov .m4v` — loops, muted, hardware-decoded
- **image** `.png .jpg .heic .gif .tiff .webp` — wrapped automatically in a slow Ken-Burns page
- **html** — anything WebKit can draw; this is the interesting one

Try the HTML route with the bundled example (canvas starfield, measured at ~2.7% CPU):

```bash
cp examples/jades-drift.html "$HOME/Library/Application Support/LiveWallpaper/wallpapers/"
```

Then click the menu-bar icon -> **jades-drift**.

### From a still image to a video loop

`tools/mkloop.swift` turns any image into a seamless pan/zoom MP4 (H.264, hardware-encoded):
`./build/mkloop in.png out.mp4 [seconds] [fps] [zoom]`.

## Starbound wallpaper (built from YOUR copy of the game)

The Starbound space backdrop is copyrighted by Chucklefish, so this repo ships the **builder**, never
the art. `tools/starbound_wallpaper.py` reads the game you already own
(`Steam/steamapps/common/Starbound/assets/packed.pak`, container format `SBAsset6`) and writes the
wallpaper, each layer drifting at its own rate for parallax:

```bash
python3 tools/starbound_wallpaper.py        # -> ~/Library/Application Support/LiveWallpaper/wallpapers/starbound-loading
```

Layers: `/celestial/sector/bg.png` (slow zoom) · `/interface/cockpit/nebula1.png` (drifting, screen
blend) · `/interface/cockpit/bgstars.png` (the one tileable layer, scrolled) · `/sky/glitters/4.png`
(sparkle drift). Note that the sector backdrop, nebula and glitters are sprites, not seamless tiles —
repeating them shows a grid, so only the star dust is tiled.

`tools/starbound_unpack.py` is a general-purpose reader for that container:

```bash
python3 tools/starbound_unpack.py --list 'nebula|starfield'
python3 tools/starbound_unpack.py --extract '^/interface/title/.*\.png$' --out ./out
```

## Performance (measured, M2 Max, 3 displays incl. a 1512x982 built-in)

| content | CPU (whole process tree) |
|---|---|
| CoreAnimation layers | 0.0% |
| video loop (1512x982) | 1.7% |
| HTML canvas wallpaper | 2.7% |

## Debug / CLI

`Sources/wphost-cli.swift` builds to `build/wphost` — the same engine without a menu bar, handy for
scripting and tests: `./build/wphost --web page.html --seconds 5`.

The app has two hidden flags used to verify it really is on screen:

```bash
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --status     # window levels + what each page rendered, then quits
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --seconds 5  # run for 5 s and exit
```

Real `--status` output from the machine this was developed on:

```
LIVEWALLPAPER level=-2147483604 desktopIcon=-2147483603 screens=3 wallpaper=starbound-loading
LIVEWALLPAPER window frame={{0, 0}, {1920, 1080}} level=-2147483604 visible=true
LIVEWALLPAPER web[0] Starbound space backdrop | layers=4 | anim=stars_drift | bodyH=1080 | asset 2043x2044
```

## Uninstall

Quit from the menu (or `pkill -x LiveWallpaper`), delete the app, and optionally
`rm -rf ~/Library/Application\ Support/LiveWallpaper`.

## Notes and limits

- Only the desktop layer is replaced; Lock Screen video is out of scope (macOS 26+ aerial-store trick).
- `Start at Login` uses `SMAppService.mainApp`, so keep the app in a stable folder.
- A macOS update can invalidate wallpaper state — hit **Reload**.
- Nothing here is notarized: it is signed ad-hoc, which is fine on your own machine. Giving the
  `.app` to someone else needs a Developer ID certificate ($99/yr) plus notarization.
- Only tested on Apple Silicon, macOS 27.

MIT licensed. Starbound and its assets are (c) Chucklefish — none of them are in this repository.
