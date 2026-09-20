#!/usr/bin/env python3
"""
starbound_mainmenu.py — the Starbound MAIN MENU backdrop as an HTML wallpaper.

What the real main menu is: /interface/windowconfig/title.config contains
    "skyBackdropDarken" : [0, 0, 0, 100]
i.e. the engine draws its celestial backdrops and darkens them ~40%; the only backdropImages
listed there are UI (blackbar + logo). The celestial backdrop comes from /celestial.config:
    "garden" : { "baseImages"   : "/celestial/system/terrestrial/horizon/textures/garden_<selector>.png",
                 "maskTextures" : "/celestial/system/terrestrial/horizon/masks/temperate/<mask>_<selector>.png",
                 "maskRange" : [1, 25], "maskPerPlanetRange" : [3, 3] }
So the menu shows a planet's curved HORIZON (left+right halves, plus three surface masks, plus the
atmosphere glow) under a starfield, darkened. This tool rebuilds exactly that composition from the
game's own textures, with the masks/layers drifting at slightly different rates.

    python3 tools/starbound_mainmenu.py                      # garden planet (default)
    python3 tools/starbound_mainmenu.py --planet midnight    # or forest, desert, snow, ocean, ...
    python3 tools/starbound_mainmenu.py --masks 6,11,17
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starbound_unpack import find_pak, parse_index  # noqa: E402

HORIZON = "/celestial/system/terrestrial/horizon"

DEFAULT_MASKS = ["6", "11", "17"]          # the engine draws maskPerPlanetRange = [3, 3]
STAR_COUNT = 260

HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Starbound main menu backdrop - LiveWallpaper</title>
<style>
  html, body { height: 100%; margin: 0; background: #05070f; overflow: hidden; }
  body { min-width: 640px; min-height: 420px; }
  .layer { position: fixed; inset: 0; }
  img.pixel { image-rendering: pixelated; }

  /* deep space */
  #space {
    background:
      radial-gradient(ellipse 80% 60% at 50% 8%, rgba(40,58,110,0.55), rgba(0,0,0,0) 70%),
      radial-gradient(ellipse 60% 40% at 20% 30%, rgba(60,40,90,0.35), rgba(0,0,0,0) 70%),
      linear-gradient(180deg, #070b16 0%, #04060d 55%, #02030a 100%);
  }

  /* starfield: the engine generates its stars procedurally, so this is procedural too */
  #stars {
    animation: drift 420s linear infinite alternate;
    background-repeat: repeat;
  }
  .starfield { display: block; width: 100%; height: 100%; }
  @keyframes drift { from { transform: translate3d(0,0,0); } to { transform: translate3d(-1.5%, -1%, 0); } }

  /* The planet: base halves + the surface masks + the atmosphere, composited (masks clipped to the
     planet) by tools/composite_pngs.swift before this page is written. */
  #horizon { position: fixed; bottom: 0; left: -15%; width: 130%; }
  #horizon img { width: 100%; display: block; }

  #glow {
    position: fixed; left: -15%; bottom: -6%; width: 130%; height: 55%;
    background: radial-gradient(ellipse 70% 100% at 50% 100%, rgba(120,190,255,0.16), rgba(0,0,0,0) 70%);
    mix-blend-mode: screen;
  }

  /* title.config: "skyBackdropDarken" : [0, 0, 0, 100] */
  #darken { background: rgba(0,0,0,0.39); }

  @media (prefers-reduced-motion: reduce) { #stars { animation: none !important; } }
</style>
</head>
<body>
  <div class="layer" id="space"></div>
  <div class="layer" id="stars"><canvas class="starfield" id="starfield"></canvas></div>
  <div id="glow"></div>
  <div id="horizon">
    <img class="pixel" src="assets/horizon.png">
  </div>
  <div class="layer" id="darken"></div>
<script>
  // procedural starfield (the engine generates its own; this is the same idea)
  (function () {
    var canvas = document.getElementById('starfield');
    var ctx = canvas.getContext('2d');
    var stars = [];
    function seed() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(window.innerWidth * dpr);
      canvas.height = Math.round(window.innerHeight * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      stars = [];
      var n = __COUNT__;
      for (var i = 0; i < n; i++) {
        var depth = 0.3 + Math.random() * 0.7;
        stars.push({
          x: Math.random(), y: Math.random() * 0.75,   // keep the field above the horizon
          r: 0.4 + depth * 1.3, depth: depth,
          tw: Math.random() * Math.PI * 2, speed: 0.3 + Math.random() * 0.9,
          hue: Math.random()
        });
      }
    }
    window.__lwStarCount = function () { return stars.length; };
    function draw(now) {
      var w = window.innerWidth, h = window.innerHeight;
      ctx.clearRect(0, 0, w, h);
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        var a = (0.35 + 0.65 * Math.abs(Math.sin(s.tw + now * 0.0004 * s.speed))) * s.depth;
        var tint = s.hue > 0.9 ? "190,215,255" : (s.hue < 0.1 ? "255,225,200" : "255,255,255");
        ctx.fillStyle = "rgba(" + tint + "," + a.toFixed(3) + ")";
        ctx.beginPath();
        ctx.arc(s.x * w, s.y * h, s.r, 0, 6.2832);
        ctx.fill();
      }
    }
    seed();
    window.addEventListener('resize', function () { seed(); });
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      draw(0);
    } else {
      (function loop() {
        draw(Date.now() - __EPOCH_PLACEHOLDER__);
        requestAnimationFrame(loop);
      })();
    }
  })();
</script>
</body>
</html>
"""


def row_html(assets_dir, left, right):
    return (f'    <div class="row">\n'
            f'      <img class="pixel" src="{assets_dir}/{left}">\n'
            f'      <img class="pixel" src="{assets_dir}/{right}">\n'
            f'    </div>')


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
    ap.add_argument("--planet", default="garden", help="planet type: garden, forest, desert, snow, ocean, midnight, ...")
    ap.add_argument("--masks", default=",".join(DEFAULT_MASKS), help="surface mask numbers, e.g. 6,11,17")
    ap.add_argument("--mask-alpha", type=float, default=0.18, help="how strongly the surface masks show")
    ap.add_argument("--shade", action="store_true", default=True, help="apply the horizon shadow pass (default on)")
    ap.add_argument("--no-shade", dest="shade", action="store_false", help="skip the shadow pass")
    ap.add_argument("--stars", type=int, default=STAR_COUNT, help="number of stars to generate")
    args = ap.parse_args()

    out = os.path.expanduser(args.out)
    assets = os.path.join(out, "assets")
    os.makedirs(assets, exist_ok=True)

    masks = [m.strip() for m in args.masks.split(",") if m.strip()]
    # planet horizon mask folder: temperate for most terrestrial types
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
            print(f"  {size:>7} bytes  {pak_path}")

    planet_rows = ""
    mask_rows = ""
    atmos_rows = ""

    # Composite the celestial stack the way the engine does: base halves, masks CLIPPED to the planet
    # (sourceAtop), then the atmosphere pass. Doing this in CSS leaves the mask silhouettes floating.
    compositor = ensure_compositor()
    canvas_w = 1764      # atmosphere pair width (882 x 2); the planet pair (789 x 2) is centred inside
    canvas_h = 202
    horizon = os.path.join(assets, "horizon.png")
    cmd = [compositor, horizon, str(canvas_w), str(canvas_h),
           "--planet", f"{args.planet}_l.png", f"{args.planet}_r.png"]
    if args.shade:
        cmd += ["--multiply", "0.45", "shadow_l.png", "shadow_r.png"]     # terminator/limb shading
    mask_files = []
    for m in masks:
        mask_files += [f"mask{m}_l.png", f"mask{m}_r.png"]
    if mask_files:
        cmd += ["--atop", str(args.mask_alpha)] + mask_files              # subtle terrain variation
    cmd += ["--screen", "atmosphere_l.png", "atmosphere_r.png"]           # glowing atmosphere rim
    print("  " + subprocess.run(cmd, capture_output=True, text=True, cwd=assets).stdout.strip())

    html = (HTML.replace("__COUNT__", str(args.stars))
                .replace("__EPOCH_PLACEHOLDER__", "window.__lwEpoch || 0"))

    index = os.path.join(out, "index.html")
    with open(index, "w") as g:
        g.write(html)
    print(f"# wallpaper written: {index}")
    print(f"# planet={args.planet} masks={masks} stars={args.stars}")


if __name__ == "__main__":
    main()
