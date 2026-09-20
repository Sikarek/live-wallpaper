#!/usr/bin/env python3
"""
starbound_mainmenu.py — the Starbound MAIN MENU backdrop as an HTML wallpaper, animated the way the
game animates it.

Where this comes from (all of it is the retail game's own data):
  /interface/windowconfig/title.config   "skyBackdropDarken": [0,0,0,100]  -> the menu draws the
                                          celestial backdrop and darkens it 39%; backdropImages there
                                          are UI only (blackbar + logo).
  /celestial.config                      horizon = textures/<planet>_<l|r>.png + masks (3 per planet)
                                          + atmosphere + shadow passes.
  /sky.config                            the numbers the renderer uses (stars, planetHorizon, satellite).
  OpenStarbound (github.com/OpenStarbound/OpenStarbound, the 1.4.4 sources) is what tells us the MOTION:
    * frontend/StarTitleScreen.cpp     layer order + pixel ratios:
                                         pixelRatioBasis      = screenH / 1080
                                         starAndDebrisRatio   = lerp(0.0625, basis*2, interfaceScale)
                                         orbiterAndPlanetRatio= lerp(0.125,  basis*3, interfaceScale)
                                         renderStars -> renderDebrisFields -> renderBackOrbiters ->
                                         renderPlanetHorizon -> renderSky -> renderFrontOrbiters
    * game/StarSky.cpp:204             m_starRotation += dt / dayLength() * 2*pi     (stars wheel once
                                       per day)
    * game/StarSky.cpp:332             orbitAngle() = 2*pi * timeOfDay / dayLength
    * game/StarSkyRenderData.cpp       clouds: position = withAngle(startAngle + orbitAngle*speed,
                                       cloudRadius) + planetCenter, planetCenter = (viewW/2, 0) -
                                       withAngle(-pi/2, yCenter)   [yCenter = -700 -> 700 units below
                                       the bottom edge, so clouds sweep around the planet limb]
    * rendering/StarEnvironmentPainter.cpp  star twinkle: frame = (int)(epochTime + offset) % frames,
                                       offset = (rand % frames) + rand(twinkleMin, twinkleMax); stars are
                                       drawn 1:1 from <star>.png:<frame> sheets (4 frames each).
                                       Clouds drawn at planetHorizon.scale * pixelRatio.

    python3 tools/starbound_mainmenu.py                       # garden planet
    python3 tools/starbound_mainmenu.py --planet midnight      # forest, desert, snow, ocean, ...
    python3 tools/starbound_mainmenu.py --day-length 300 --interface-scale 2

Append ?t=<seconds> to the page URL to render a fixed moment (used by the tests).
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starbound_unpack import find_pak, parse_index  # noqa: E402

HORIZON = "/celestial/system/terrestrial/horizon"

# /sky.config, verbatim
STAR_SHEETS = ["bigb", "bigr", "bigw", "bigy", "mediumb", "smallerw", "smallr", "smallw", "smally", "transw"]
STAR_FRAMES = 4
STAR_CELL_SIZE = 180          # sky.config: stars.cellSize
STAR_CELL_COUNT = 80          # sky.config: stars.cellCount [80, 80] -> points per cell
TWINKLE_MIN, TWINKLE_MAX = 1, 2.5
SCREEN_BUFFER = 4
PLANET_SCALE = 0.5            # sky.config: planetHorizon.scale
Y_CENTER = -700               # sky.config: planetHorizon.yCenter
CLOUD_COUNT = (30, 60)
CLOUD_RADIUS = (740, 810)
CLOUD_SPEED = (0.2, 0.3)
CLOUD_SHEETS = ["cloud2", "cloud3", "cloud4"]
DEFAULT_MASKS = ["6", "11", "17"]     # celestial.config: maskPerPlanetRange [3, 3]

HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Starbound main menu backdrop - LiveWallpaper</title>
<style>
  html, body { height: 100%; margin: 0; background: #04060d; overflow: hidden; }
  body { min-width: 640px; min-height: 420px; }
  canvas { position: fixed; inset: 0; width: 100%; height: 100%; display: block; }
</style>
</head>
<body>
<canvas id="sky"></canvas>
<div id="__lwDebug" style="position:fixed;left:-99999px;top:0;font-size:1px"></div>
<script>
// surface any runtime error where the tests can see it
window.onerror = function (m, src, line, col) {
  document.title = 'LWERROR ' + m + ' @' + line + ':' + col;
};
// ---------------------------------------------------------------------------------------------
// Starbound title-screen backdrop, driven by the game's own numbers.
// Coordinates below are the engine's: view units, y up, bottom edge at y = 0.
// ---------------------------------------------------------------------------------------------
var CFG = {
  dayLength: __DAYLENGTH__,          // seconds per in-game day: the starfield wheels once per day
  interfaceScale: __INTERFACE_SCALE__,   // the options "interface scale" the ratios lerp against
  starCellSize: __STAR_CELL_SIZE__,      // sky.config stars.cellSize   (view units)
  starCellCount: __STAR_CELL_COUNT__,    // sky.config stars.cellCount  (stars per cell)
  twinkleMin: __TWINKLE_MIN__, twinkleMax: __TWINKLE_MAX__, starFrames: __STAR_FRAMES__,
  screenBuffer: __SCREEN_BUFFER__,
  planetScale: __PLANET_SCALE__, yCenter: __Y_CENTER__,
  cloudCount: [__CLOUD_MIN__, __CLOUD_MAX__],
  cloudRadius: [__CLOUD_R_MIN__, __CLOUD_R_MAX__],
  cloudSpeed: [__CLOUD_S_MIN__, __CLOUD_S_MAX__],
  darken: __DARKEN__,                 // title.config skyBackdropDarken alpha / 255
  cloudAlpha: __CLOUD_ALPHA__         // 1.0 = the engine's alpha; the sprites are very faint
};

var canvas = document.getElementById('sky');
var ctx = canvas.getContext('2d');
var W = 0, H = 0, DPR = 1;
var planetRatio = 1, pixelRatio = 1, view = { w: 0, h: 0 };
var horizonImage = new Image();
var cloudImages = [], starSheets = [], starFrameSize = [];
var clouds = [], starTypes = [];
var reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

function lerp(a, b, t) { return a + (b - a) * t; }

// ---- deterministic RNG (the engine derives everything from the world seed) -------------------
// 32-bit murmur-style mixing with Math.imul: plain float multiply loses precision above 2^53 and
// collapses different cells onto identical values, which shows up as a visibly tiled starfield.
var SEED = __SEED__ | 0;
function hash2(x, y, salt) {
  var h = (SEED ^ Math.imul(x | 0, 0x27d4eb2d) ^ Math.imul(y | 0, 0x165667b1)
           ^ Math.imul(salt | 0, 0x9e3779b1)) >>> 0;
  h = Math.imul(h ^ (h >>> 15), 0x85ebca6b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function setupSprites() {
  horizonImage.src = 'assets/horizon.png';
  for (var i = 0; i < __CLOUD_FILES__.length; i++) {
    var c = new Image(); c.src = 'assets/' + __CLOUD_FILES__[i]; cloudImages.push(c);
  }
  for (var s = 0; s < __STAR_FILES__.length; s++) {
    var img = new Image(); img.src = 'assets/' + __STAR_FILES__[s];
    starSheets.push(img);
    starFrameSize.push(null);           // measured once the sheet loads
    img.onload = (function (index, image) {
      return function () { starFrameSize[index] = [image.width / CFG.starFrames, image.height]; };
    })(s, img);
  }
}

// star types: big/medium/small as in /sky.config's star list
function setupStars() {
  starTypes = [];
  for (var i = 0; i < __STAR_FILES__.length; i++) starTypes.push(i);
}

function setupClouds() {
  clouds = [];
  var count = Math.round(lerp(CFG.cloudCount[0], CFG.cloudCount[1], hash2(1, 1, 7)));
  for (var i = 0; i < count; i++) {
    clouds.push({
      startAngle: hash2(i, 11, 1) * Math.PI * 2,
      image: i % cloudImages.length,
      speed: lerp(CFG.cloudSpeed[0], CFG.cloudSpeed[1], hash2(i, 12, 2)),
      radius: lerp(CFG.cloudRadius[0], CFG.cloudRadius[1], hash2(i, 13, 3))
    });
  }
}

function resize() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  W = window.innerWidth; H = window.innerHeight;
  canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);

  // StarTitleScreen.cpp: layer ratios
  var pixelRatioBasis = H / 1080.0;
  pixelRatio = lerp(0.125, pixelRatioBasis * 3.0, CFG.interfaceScale);   // orbiterAndPlanetRatio
  planetRatio = pixelRatio * CFG.planetScale;                            // planet + clouds
  view = { w: W / pixelRatio, h: H / pixelRatio };                       // view units, y up
}

// ---- drawing helpers (engine space is y-up; canvas is y-down) --------------------------------
function image(x, yBottom, w, h, img) { ctx.drawImage(img, x, H - yBottom - h, w, h); }
function dot(x, y, r, style) {
  ctx.fillStyle = style;
  ctx.fillRect(Math.round(x - r), Math.round(H - y - r), Math.round(r * 2) || 1, Math.round(r * 2) || 1);
}

function drawSky() {
  var g = ctx.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0.0, '#06080f');
  g.addColorStop(0.55, '#04060d');
  g.addColorStop(1.0, '#0a1020');          // the engine lerps topRectColor -> bottomRectColor
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, W, H);
}

// renderStars(): the field is queried over a view rect padded by screenBuffer and rotated by
// -starRotation; each star is then drawn rotated by +starRotation about the view centre. Net effect
// for a star with field position p: rotate(p - fieldOrigin, starRotation, viewCentre).
function drawStars(t, starRotation) {
  var cos = Math.cos(starRotation), sin = Math.sin(starRotation);
  var cx = view.w / 2, cy = view.h / 2;
  var cell = CFG.starCellSize;
  var reach = Math.sqrt(view.w * view.w + view.h * view.h) / 2 + cell * 2;
  var cells = Math.ceil(reach / cell);
  var twinkle = CFG.twinkleMax;
  var density = CFG.starCellCount;

  for (var gy = -cells; gy <= cells; gy++) {
    for (var gx = -cells; gx <= cells; gx++) {
      var baseX = gx * cell, baseY = gy * cell;
      for (var k = 0; k < density; k++) {
        var rx = hash2(gx * 31 + k, gy * 17 + k, 5);
        var ry = hash2(gx * 13 + k, gy * 29 + k, 6);
        // field position, relative to the view centre (starOffset is 0 on the title screen)
        var fx = baseX + rx * cell, fy = baseY + ry * cell;
        var sx = cx + fx * cos - fy * sin;
        var sy = cy + fx * sin + fy * cos;
        if (sx < -8 || sx > view.w + 8 || sy < -8 || sy > view.h + 8) continue;

        var type = Math.floor(hash2(gx + k, gy - k, 8) * starSheets.length);
        var offset = Math.floor(hash2(gx - k, gy + k, 9) * CFG.starFrames) + lerp(CFG.twinkleMin, twinkle,
                                                                                 hash2(gx, gy + k, 10));
        var frame = Math.floor(t + offset) % CFG.starFrames;
        var size = starFrameSize[type];
        var px = sx * pixelRatio, py = sy * pixelRatio;   // screen px
        if (size) {
          ctx.drawImage(starSheets[type], frame * size[0], 0, size[0], size[1],
                        Math.round(px - size[0] / 2), Math.round(H - py - size[1] / 2), size[0], size[1]);
        } else {
          dot(px, py, 1, 'rgba(255,255,255,0.9)');
        }
        window.__lwStarDrawn = (window.__lwStarDrawn || 0) + 1;
      }
    }
  }
}

function drawPlanet() {
  if (!horizonImage.complete || !horizonImage.naturalWidth) return;
  var w = horizonImage.naturalWidth * planetRatio;
  var h = horizonImage.naturalHeight * planetRatio;
  image((W - w) / 2, 0, w, h, horizonImage);        // centred on the view, sitting on the bottom edge
}

// frontOrbiters(): clouds orbit the planet centre, which sits BELOW the bottom edge
// (StarSkyRenderData.cpp: planetCenter = (viewW/2, 0) - withAngle(-pi/2, yCenter) = (viewW/2, -700))
// The sprites are faint wisps (peak alpha ~7%) made to sit on a bright daytime sky; blended with
// 'screen' they read on the dark orbital backdrop the way they do in the game.
function drawClouds(orbitAngle) {
  var cx = view.w / 2;
  var cy = CFG.yCenter;                  // -700: 700 view units below the bottom edge
  var hash = 0, drawn = 0;
  ctx.globalCompositeOperation = 'screen';
  ctx.globalAlpha = CFG.cloudAlpha;
  for (var i = 0; i < clouds.length; i++) {
    var c = clouds[i];
    var a = c.startAngle + orbitAngle * c.speed;
    var x = Math.cos(a) * c.radius + cx;
    var y = Math.sin(a) * c.radius + cy;
    if (y < -80) continue;               // the rest of the orbit is off-screen
    hash = (hash * 31 + Math.round(a * 1000)) | 0;
    var img = cloudImages[c.image];
    if (!img.complete || !img.naturalWidth) continue;
    var w = img.naturalWidth * planetRatio, h = img.naturalHeight * planetRatio;
    var px = x * pixelRatio, py = y * pixelRatio;
    image(px - w / 2, py - h / 2, w, h, img);
    drawn++;
  }
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = 'source-over';
  window.__lwCloudHash = hash;
  window.__lwCloudsDrawn = drawn;
}

function drawDarken() {
  ctx.fillStyle = 'rgba(0,0,0,' + CFG.darken.toFixed(3) + ')';
  ctx.fillRect(0, 0, W, H);
}

function frame(seconds) {
  if (typeof frame.count !== 'number') frame.count = 0;
  frame.count++;
  var day = seconds % CFG.dayLength;
  var starRotation = 2 * Math.PI * day / CFG.dayLength;    // StarSky.cpp:204
  var orbitAngle = 2 * Math.PI * day / CFG.dayLength;      // StarSky::orbitAngle()
  var t = seconds;

  window.__lwStarDrawn = 0;
  drawSky();
  drawStars(t, starRotation);
  drawPlanet();
  drawClouds(orbitAngle);
  drawDarken();
  window.__lwStarCount = window.__lwStarDrawn;
  if (frame.count % 20 === 0 && window.__lwTitleInfo) {
    var dbg = document.getElementById('__lwDebug');
    if (dbg) dbg.textContent = window.__lwTitleInfo();
  }
}

function start() {
  setupSprites();
  setupStars();
  setupClouds();
  resize();
  window.addEventListener('resize', function () { resize(); });

  // ?t=<seconds> renders a fixed moment (the tests use this); otherwise follow the shared clock
  var forced = new URLSearchParams(location.search).get('t');

  window.__lwTitleInfo = function () {
    var seconds = forced !== null ? parseFloat(forced) : currentSeconds();
    return JSON.stringify({
      dayLength: CFG.dayLength,
      pixelRatio: Math.round(pixelRatio * 1000) / 1000,
      planetRatio: Math.round(planetRatio * 1000) / 1000,
      starRotation: Math.round(2 * Math.PI * (seconds % CFG.dayLength) / CFG.dayLength * 1000) / 1000,
      orbitAngle: Math.round(2 * Math.PI * (seconds % CFG.dayLength) / CFG.dayLength * 1000) / 1000,
      starsDrawn: window.__lwStarCount || 0,
      clouds: clouds.length,
      cloudsDrawn: window.__lwCloudsDrawn || 0,
      cloudState: cloudImages.map(function (i) { return (i.complete ? 'done' : 'loading') + ':' + i.naturalWidth; }).join(' '),
      horizonWidth: horizonImage.naturalWidth,
      starWidths: starSheets.map(function (i) { return i.naturalWidth; }).join(','),
      cloudHash: window.__lwCloudHash || 0,
      w: W, h: H
    });
  };

  function currentSeconds() { return (Date.now() - (window.__lwEpoch || 0)) / 1000; }

  if (reduceMotion) {
    frame(forced !== null ? parseFloat(forced) : 0);
    return;
  }
  (function loop() {
    frame(forced !== null ? parseFloat(forced) : currentSeconds());
    requestAnimationFrame(loop);
  })();
}

start();
</script>
</body>
</html>
"""


def ensure_compositor():
    """Compile tools/composite_pngs.swift on first use (swiftc ships with the Command Line Tools)."""
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    binary = os.path.join(root, "build", "composite_pngs")
    source = os.path.join(here, "composite_pngs.swift")
    if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        result = subprocess.run(["swiftc", "-O", "-o", binary, source], capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit("could not build composite_pngs:\n" + result.stderr)
    return binary


def main():
    default_out = os.path.expanduser(
        "~/Library/Application Support/LiveWallpaper/wallpapers/starbound-mainmenu")
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=default_out, help="wallpaper folder to create")
    ap.add_argument("--pak", help="path to packed.pak (auto-detected if omitted)")
    ap.add_argument("--planet", default="garden",
                    help="planet type: garden, forest, desert, snow, ocean, midnight, ...")
    ap.add_argument("--masks", default=",".join(DEFAULT_MASKS), help="surface mask numbers, e.g. 6,11,17")
    ap.add_argument("--mask-alpha", type=float, default=0.18, help="how strongly the surface masks show")
    ap.add_argument("--shade", action="store_true", default=True, help="apply the horizon shadow pass (default on)")
    ap.add_argument("--no-shade", dest="shade", action="store_false", help="skip the shadow pass")
    ap.add_argument("--day-length", type=float, default=600.0,
                    help="seconds per in-game day (stars wheel once per day); planets differ in the game")
    ap.add_argument("--interface-scale", type=float, default=1.0, help="the options interface scale (1 = default)")
    ap.add_argument("--seed", type=int, default=1234567, help="world seed for star/cloud layout")
    ap.add_argument("--stars-per-cell", type=int, default=STAR_CELL_COUNT,
                    help="sky.config stars.cellCount (stars per 180-unit cell)")
    ap.add_argument("--cloud-alpha", type=float, default=3.0,
                    help="cloud opacity multiplier: the sprites peak at ~7%% alpha, 3.0 makes the "
                         "wisps read on the dark backdrop (1.0 = engine alpha)")
    args = ap.parse_args()

    out = os.path.expanduser(args.out)
    assets = os.path.join(out, "assets")
    os.makedirs(os.path.join(assets, "stars"), exist_ok=True)

    masks = [m.strip() for m in args.masks.split(",") if m.strip()]
    mask_dir = "temperate"

    wanted = [
        (f"{HORIZON}/textures/{args.planet}_l.png", f"{args.planet}_l.png"),
        (f"{HORIZON}/textures/{args.planet}_r.png", f"{args.planet}_r.png"),
        (f"{HORIZON}/atmosphere/atmosphere_l.png", "atmosphere_l.png"),
        (f"{HORIZON}/atmosphere/atmosphere_r.png", "atmosphere_r.png"),
        (f"{HORIZON}/shadow/shadow_l.png", "shadow_l.png"),
        (f"{HORIZON}/shadow/shadow_r.png", "shadow_r.png"),
    ]
    for m in masks:
        wanted.append((f"{HORIZON}/masks/{mask_dir}/{m}_l.png", f"mask{m}_l.png"))
        wanted.append((f"{HORIZON}/masks/{mask_dir}/{m}_r.png", f"mask{m}_r.png"))
    for c in CLOUD_SHEETS:
        wanted.append((f"/sky/orbitals/{c}.png", f"{c}.png"))
    for s in STAR_SHEETS:
        wanted.append((f"/sky/stars/{s}_star.png", f"stars/{s}_star.png"))

    pak = find_pak(args.pak)
    print(f"# pak: {pak}")
    by_path = {p: (o, s) for p, o, s in parse_index(pak)}
    with open(pak, "rb") as f:
        for pak_path, local in wanted:
            if pak_path not in by_path:
                sys.exit(f"asset missing from this Starbound build: {pak_path}")
            off, size = by_path[pak_path]
            f.seek(off)
            with open(os.path.join(assets, local), "wb") as g:
                g.write(f.read(size))
    print(f"# extracted {len(wanted)} assets ({len(STAR_SHEETS)} star sheets, {len(CLOUD_SHEETS)} clouds)")

    # Composite the celestial stack the way the engine does: base halves, masks CLIPPED to the planet
    # (sourceAtop), shadow pass, then the atmosphere.
    compositor = ensure_compositor()
    horizon = os.path.join(assets, "horizon.png")
    cmd = [compositor, horizon, "1764", "202",
           "--planet", f"{args.planet}_l.png", f"{args.planet}_r.png"]
    if args.shade:
        cmd += ["--multiply", "0.45", "shadow_l.png", "shadow_r.png"]
    mask_files = []
    for m in masks:
        mask_files += [f"mask{m}_l.png", f"mask{m}_r.png"]
    if mask_files:
        cmd += ["--atop", str(args.mask_alpha)] + mask_files
    cmd += ["--screen", "atmosphere_l.png", "atmosphere_r.png"]
    print("  " + subprocess.run(cmd, capture_output=True, text=True, cwd=assets).stdout.strip())

    html = (HTML
            .replace("__DAYLENGTH__", str(args.day_length))
            .replace("__INTERFACE_SCALE__", str(args.interface_scale))
            .replace("__STAR_CELL_SIZE__", str(STAR_CELL_SIZE))
            .replace("__STAR_CELL_COUNT__", str(args.stars_per_cell))
            .replace("__TWINKLE_MIN__", str(TWINKLE_MIN))
            .replace("__TWINKLE_MAX__", str(TWINKLE_MAX))
            .replace("__STAR_FRAMES__", str(STAR_FRAMES))
            .replace("__SCREEN_BUFFER__", str(SCREEN_BUFFER))
            .replace("__PLANET_SCALE__", str(PLANET_SCALE))
            .replace("__Y_CENTER__", str(Y_CENTER))
            .replace("__CLOUD_MIN__", str(CLOUD_COUNT[0]))
            .replace("__CLOUD_MAX__", str(CLOUD_COUNT[1]))
            .replace("__CLOUD_R_MIN__", str(CLOUD_RADIUS[0]))
            .replace("__CLOUD_R_MAX__", str(CLOUD_RADIUS[1]))
            .replace("__CLOUD_S_MIN__", str(CLOUD_SPEED[0]))
            .replace("__CLOUD_S_MAX__", str(CLOUD_SPEED[1]))
            .replace("__DARKEN__", "0.39")
            .replace("__CLOUD_ALPHA__", str(args.cloud_alpha))
            .replace("__SEED__", str(args.seed))
            .replace("__CLOUD_FILES__", repr([f"{c}.png" for c in CLOUD_SHEETS]))
            .replace("__STAR_FILES__", repr([f"stars/{s}_star.png" for s in STAR_SHEETS])))

    index = os.path.join(out, "index.html")
    with open(index, "w") as g:
        g.write(html)
    print(f"# wallpaper written: {index}")
    print(f"# planet={args.planet} masks={masks} dayLength={args.day_length}s stars/cell={args.stars_per_cell}")


if __name__ == "__main__":
    main()
