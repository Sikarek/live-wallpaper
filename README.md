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

A sparkles icon appears in the menu bar: **LiveWallpaper Settings…** (⌘O), the wallpaper list,
Pause / Resume, Reload (⌘R), Open Wallpapers Folder, Start at Login, Quit.

## The window

The menu-bar item → **LiveWallpaper Settings…**, double-clicking the app, or ⌘O opens the GUI. A
re-launch of a running copy just brings this window forward (no second instance).

```
┌─ Wallpapers ─────────┬─ live preview of the selected wallpaper ────────┐
│ starbound-loading  ✓ │  (HTML renders in WebKit, video loops in AV)    │
│   HTML / animation   │                                                 │
│                      │  starbound-loading        [Use this wallpaper]  │
│  [Add…] [Reveal] [🗑] ├─────────────────────────────────────────────────┤
│                      │ Settings                                        │
│                      │  [ ] Pause wallpaper     [ ] Start at login     │
│                      │  3 displays — same wallpaper on all  [Reload]   │
│                      │  ~/…/LiveWallpaper/wallpapers    [Open folder]   │
└──────────────────────┴─────────────────────────────────────────────────┘
```

- **Add…** — copies any HTML file, video, image or folder into the wallpapers folder.
- **Use on all displays** — applies the selected wallpaper to every display immediately, no restart.
- **Sync all displays** — on: one wallpaper everywhere with the animation phase locked across screens.
  Off: a picker per display, so each monitor can run a different wallpaper.
- **Trash** — deletes the selected wallpaper from the wallpapers folder.
- **Pause wallpaper** — hides it without quitting. **Start at login** — via `SMAppService`.
- The preview is the real thing: the same WebKit/video content, rendered live in the window.

## Displays: sync, per-display, any resolution

Every display gets its own borderless window created **exactly** from `NSScreen.frame`, rebuilt the
moment the display configuration changes (plug/unplug, resolution, arrangement, HDR/scaling change).

| mode | behaviour |
|---|---|
| sync (default) | one wallpaper on every display, **phase-locked**: all pages are driven from one shared wall clock, so the Starfield/Nebula is at the same point on every screen. WebKit throttles individual views, which is why letting each page run its own timeline drifts (measured 579 ms apart) — with the shared clock it measured within **2–4 ms**. |
| per-display | a popup per display, stored per display id, so a monitor keeps its wallpaper when unplugged and plugged back in |
| video | one decoder shared by every screen (measured: **1 player for 3 screens**), so frames are identical by construction instead of merely similar |

Resolution handling: the wallpaper is laid out at each display's own size (verified: 1920×1080 and
1512×982 pages side by side, `devicePixelRatio` respected), video uses `resizeAspectFill`, and every
page receives CSS variables it can adapt to — `--screen-width`, `--screen-height`, `--screen-scale`,
`--screen-aspect` — plus `window.__lwEpoch` for JS/canvas wallpapers that want to phase-lock themselves.
A geometry self-check a second after applying corrects a stale first-pass display arrangement, which
the window server sometimes hands a freshly launched process.

macOS also fires `didChangeScreenParametersNotification` spuriously — measured **every ~2 seconds** on
this machine. Acting on those re-created every window and reloaded every page, which showed up as the
desktop picture flashing back to the Mac wallpaper. The app now keys off a *layout signature*
(display ids + frames + scales) and only rebuilds when the layout genuinely differs.

Related smoothness work: new windows are created before the old ones are retired (no uncovered gap),
a `ProcessInfo` activity keeps App Nap / automatic termination from suspending the WebKit content,
terminated content processes reload themselves, the page background is transparent so the window's
scene colour shows during a load, the title wallpaper's clock starts from a fixed origin (so a reload
or relaunch continues the sky instead of snapping back), and the canvas draws at ~30 fps.

Run the whole thing as a test:

```bash
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --self-test
# 14-15 checks: geometry per display, resolution adaptation, phase sync, motion, per-display
# assignment, shared video player, dynamic resize, display-change rebuild. Exit code 0 = passed.
```

### Opening it, and the `-10825` gotcha

A Dock-less (accessory) app has to implement `applicationShouldHandleReopen`. Without it, LaunchServices
cannot hand a re-launch to the running instance and `open LiveWallpaper.app` fails with
`_LSOpenURLsWithCompletionHandler() failed with error -10825` **whenever the app is already running** —
which looks exactly like "the app won't open". This app implements it: a re-launch brings the settings
window to the front (one instance, no stacking).

A bundle LaunchServices has never seen can fail the same way once, which is why `./build.sh --install`
registers the fresh bundle with `lsregister` before launching it.

From a shell with no GUI session (ssh, agent), `open` may not be usable at all — use the LaunchAgent,
which is also what brings it back at login:

```bash
sed "s|__APP__|$HOME/Applications/LiveWallpaper.app|g; \
     s|__BUNDLE_ID__|com.sikarek.livewallpaper|g; \
     s|__LOG__|$HOME/Library/Logs/LiveWallpaper.log|g" \
  support/launchagent.plist > ~/Library/LaunchAgents/com.sikarek.livewallpaper.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sikarek.livewallpaper.plist
# restart / remove it again:
launchctl kickstart -k gui/$(id -u)/com.sikarek.livewallpaper
launchctl bootout    gui/$(id -u)/com.sikarek.livewallpaper
```

`support/LiveWallpaper.command` (installed next to the app) is a double-clickable launcher for the same
situation: it starts the binary directly and prints the pid and the stop/restart commands.

The in-app **Start at Login** toggle (`SMAppService`) does the same thing from the GUI; a single-instance
guard stops the two from stacking.

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

## Starbound main menu (animated title screen)

`tools/starbound_mainmenu.py` rebuilds the title screen exactly as the engine draws it, motion included.
The game's own data says what it is and what moves:

```
/interface/windowconfig/title.config   skyBackdropDarken [0,0,0,100] -> backdrop darkened 39%
/celestial.config                      horizon = textures/<planet>_<l|r>.png + 3 masks + atmosphere
/sky.config                            stars.cellSize 180, cellCount 80, twinkle 1..2.5, frames 4
                                       planetHorizon.scale 0.5, yCenter -700, 30-60 clouds,
                                       cloudRadius 740..810, cloudSpeed 0.2..0.3
OpenStarbound (public 1.4.4 sources):
  frontend/StarTitleScreen.cpp         layer order + the pixel ratios
  game/StarSky.cpp:204                 starRotation += dt / dayLength * 2pi   (sky wheels once a day)
  game/StarSky.cpp:332                 orbitAngle = 2pi * timeOfDay / dayLength
  game/StarSkyRenderData.cpp           clouds orbit the planet centre below the bottom edge
  rendering/StarEnvironmentPainter.cpp star frames twinkle on the epoch clock; sprites drawn 1:1
```

The wallpaper does that on a canvas: real 4-frame star sprites twinkling, the starfield wheeling once
per `--day-length` seconds, and the game's own cloud sprites orbiting the planet limb.

### The mechanics that make it smooth (and are implemented here)

```
app/StarMainApplication_sdl.cpp   TickRateApproacher m_updateTicker(60.0f, 1.0f)
                                  -> the sky advances in FIXED 1/60 s steps with catch-up,
                                     not by whatever the frame delta happened to be
                                  setVSyncEnabled(...) -> one drawn frame per display refresh
game/StarSky.cpp:130              m_time += dt   -> a monotonic accumulator, never a wall-clock
                                     lookup, so nothing can jump
rendering/StarEnvironmentPainter  star frame = (int)(epochTime + offset) % 4, offset carries a
                                     fractional rand(twinkleMin..Max) -> twinkle is smeared, never
                                     a synchronised blink
                                  sprites drawn at fractional Vec2F positions
                                  TextureFiltering::Nearest by default -> pixels stay crisp
```

All four are in `tools/starbound_mainmenu.py`: fixed-step accumulator seeded from a fixed origin, one
draw per refresh, per-star fractional twinkle offsets, sub-pixel star positions, and nearest filtering
for the planet while the small star sprites use smoothing so a slow drift glides instead of stepping.
Measured: median frame 17 ms (59 fps) on the Retina display and 10 ms (100 fps) on the 100 Hz
monitors, with the simulation stepping at the engine's 60 Hz; 14,465 px (0.97% of the frame) change
in 0.25 s of motion. Append
`?t=<seconds>` to the page URL to render a fixed moment (the tests use it).

```bash
python3 tools/starbound_mainmenu.py                       # garden planet, 600 s day
python3 tools/starbound_mainmenu.py --planet midnight --day-length 300
python3 tools/starbound_mainmenu.py --cloud-alpha 1.0     # literal engine alpha (the wisps are ~7%)
```

Measured: 82,989 px (5.6% of the frame) change across 36 degrees of star rotation.

## Lock Screen, and coming back after a restart

macOS gives no API for custom live lock-screen content: the lock screen and the login window are drawn
by the system before your session exists, and the only animated thing it will show is one of Apple's
own aerial videos. So the same scene is baked into a video loop and takes over the *selected aerial's*
slot — which is what every lock-screen-video app does.

```bash
build/rendertitle ~/Library/Application\ Support/LiveWallpaper/lockscreen/starbound.mov \
    "$HOME/Library/Application Support/LiveWallpaper/wallpapers/starbound-mainmenu/assets" \
    --width 3840 --height 2160 --fps 30 --seconds 300    # one full star revolution = seamless loop
python3 tools/lockscreen.py --status                     # selected aerial + is the slot ours?
python3 tools/lockscreen.py --install .../starbound.mov  # back up Apple's file, take the slot
python3 tools/lockscreen.py --restore                    # put Apple's original back
```

**The format matters, and it is specific.** The manifest entry for an aerial is keyed
`url-4K-SDR-240FPS`, and Apple's own files here are 3840x2160, hvc1, **10-bit, 239.76 fps, Rec.709
primaries with sRGB transfer, no audio**. A 30 fps / 8-bit file in that slot gets mishandled by the
system's wallpaper extension (it would show wrong, or nothing at all); `rendertitle` therefore encodes
to match, repeating each rendered frame so the 240 fps timebase costs almost nothing:

```bash
build/rendertitle .../starbound.mov <wallpaper-assets-dir> \
    --width 3840 --height 2160 --fps 30 --encode-fps 240 --seconds 180
python3 tools/lockscreen.py --install .../starbound.mov   # video + the asset's still image
python3 tools/lockscreen.py --verify                      # format + is the system decoding it?
python3 tools/lockscreen.py --reapply                     # nudge the extension's cache
```

`--verify` checks the two things that indicate health: the file matches Apple's encoding, and a
`coremedia.videodecoder` process spawned by the *aerials* extension is running (that process is the
system actually playing the slot; no decoder means it refused the file). The one thing only you can
confirm is the lock screen itself — it cannot be captured programmatically. Press Control-Command-Q.

Order of events after a restart:

```
1  login window at boot      draws the same aerial slot -> your scene, before you even log in
2  after login               login LaunchAgent (RunAtLoad) starts the live desktop wallpaper
3  if the app is ever killed  KeepAlive brings it straight back (tested with kill -9)
4  Quit from the menu         deregisters the agent first, so quitting sticks
```

Caveats: re-picking a wallpaper in System Settings, or a macOS update, can re-download Apple's video
and undo the lock screen — re-run `--install`. And the lock screen shows the *video*, not the live
canvas: same scene, but it cannot react or change.

### The macOS 26 freeze bug (and the workaround this repo applies)

A **custom** aerial video plays once and then goes static on every later lock. It is not your file: it
is a defect in `WallpaperExtensionKit`'s video-player state machine — on a re-lock, `WallpaperAgent`
sends `activityState = active` and the player's `ramp`/`preroll` state is not reset for non-Apple
entries. Apple's own aerials go through `ShuffleWallpaper` and are unaffected.

The workaround (what the small community daemons do too) is to restart `WallpaperAerialsExtension`
while the lock animation plays, so the player starts fresh — invisible, because it happens during the
transition. LiveWallpaper does this itself: `tools/lockscreen.py --install` writes a marker file, and
the app then restarts that extension on `com.apple.screenIsLocked` / `screenIsUnlocked` / wake from
sleep — but only while the marker exists, so it never touches the system's own wallpaper otherwise.

```bash
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --simulate-lock   # exercises that handler
```

## Performance (measured, M2 Max, 3 displays incl. a 1512x982 Retina built-in)

| content | CPU (whole process tree) |
|---|---|
| HTML/CSS wallpaper (Starbound backdrop, all 3 screens) | 0.8% avg, 2.2% peak |
| video loop, one shared player for 3 screens | 0.9% avg, 2.0% peak |

Those figures include the animation-sync loop.

## Debug / CLI

`Sources/wphost-cli.swift` builds to `build/wphost` — the same engine without a menu bar, handy for
scripting and tests: `./build/wphost --web page.html --seconds 5`.

The app has hidden flags used to verify it is really on screen:

```bash
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --status                 # levels, status item, what each page rendered
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --seconds 5              # run for 5 s and exit
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --self-test              # 14-15 end-to-end checks, exit 0 = all passed
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --self-test --wallpaper videoloop
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --wallpaper jades-drift  # override the saved choice
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --dump-a11y              # the window's accessibility tree
./build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper --dump-ui out.png        # render the window to a PNG
```

`--dump-a11y` is the trustworthy way to check the GUI: it prints every control with its role, label and
frame, via the same accessibility API VoiceOver uses. Rendering a SwiftUI window with `cacheDisplay`
(`--dump-ui`) is unreliable — SwiftUI draws into layers it does not hand to that path, so the PNG comes
back missing most of the controls.

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
