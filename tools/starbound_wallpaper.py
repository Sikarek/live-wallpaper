#!/usr/bin/env python3
"""
starbound_wallpaper.py — build the Starbound space backdrop as an HTML wallpaper.

Pulls the space art out of the copy of Starbound installed on YOUR machine (the art is
copyrighted by Chucklefish, so this repo ships the builder, never the assets) and writes a
wallpaper folder that LiveWallpaper can display.

    python3 tools/starbound_wallpaper.py                 # -> ~/Library/Application Support/LiveWallpaper/wallpapers/starbound-loading
    python3 tools/starbound_wallpaper.py --out ./wallpapers/starbound-loading

Layers, back to front (the same sprites the game composites for its space backdrop):
    /celestial/sector/bg.png          sector backdrop, 2043x2044  -> one cover-fit sprite, slow zoom
    /interface/cockpit/nebula1.png    soft nebula cloud, 1024x1024 -> one sprite, drifting, screen blend
    /interface/cockpit/bgstars.png    star dust, 1024x1024        -> tiled (natural noise) and scrolled
    /sky/glitters/4.png               sparkle cloud, 845x670      -> one sprite, drifting, screen blend

Important: the sector backdrop, nebula1 and glitters are *sprites* (a soft blob on transparency),
not seamless tiles. Repeating them produces a visible grid, so only the star dust layer is tiled.
No third-party dependencies.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starbound_unpack import find_pak, parse_index  # noqa: E402

# (id, asset path in the pak, local filename)
ASSETS = [
    ("sector",  "/celestial/sector/bg.png",       "sector_bg.png"),
    ("nebula",  "/interface/cockpit/nebula1.png", "nebula.png"),
    ("stars",   "/interface/cockpit/bgstars.png", "stars.png"),
    ("glitter", "/sky/glitters/4.png",            "glitters.png"),
]

HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Starbound space backdrop - LiveWallpaper</title>
<style>
  html, body { height: 100%; margin: 0; background: #000; overflow: hidden; }
  body { min-width: 640px; min-height: 420px; filter: brightness(1.4) saturate(1.15); }
  .layer { position: fixed; inset: 0; will-change: transform, background-position; }

  /* back: the sector backdrop, one cover-fit sprite that breathes slowly */
  #sector {
    background: url(assets/sector_bg.png) center / cover no-repeat;
    animation: sector_zoom 300s ease-in-out infinite alternate;
  }
  @keyframes sector_zoom {
    from { transform: scale(1.02) translate3d(0, 0, 0); }
    to   { transform: scale(1.16) translate3d(-1.5%, -1%, 0); }
  }

  /* nebula cloud, drifting slowly the other way */
  #nebula {
    background: url(assets/nebula.png) center / cover no-repeat;
    opacity: 0.85;
    mix-blend-mode: screen;
    animation: nebula_drift 220s ease-in-out infinite alternate;
  }
  @keyframes nebula_drift {
    from { transform: scale(1.25) translate3d(-3%, 2%, 0); }
    to   { transform: scale(1.35) translate3d(3%, -2%, 0); }
  }

  /* star dust: the one genuinely tileable layer, so it scrolls as a field */
  #stars {
    background: url(assets/stars.png) repeat;
    background-size: 1024px 1024px;
    mix-blend-mode: screen;
    animation: stars_drift 90s linear infinite;
  }
  @keyframes stars_drift {
    from { background-position: 0 0; }
    to   { background-position: -1024px -1024px; }
  }

  /* sparkles, slowest and faintest */
  #glitter {
    background: url(assets/glitters.png) center / cover no-repeat;
    opacity: 0.30;
    mix-blend-mode: screen;
    animation: glitter_drift 260s ease-in-out infinite alternate;
  }
  @keyframes glitter_drift {
    from { transform: scale(1.3) translate3d(2%, -1%, 0); }
    to   { transform: scale(1.45) translate3d(-2%, 1.5%, 0); }
  }

  #vignette {
    position: fixed; inset: 0; pointer-events: none;
    background: radial-gradient(ellipse at 50% 50%, rgba(0,0,0,0) 45%, rgba(0,0,0,0.5) 100%);
  }
  @media (prefers-reduced-motion: reduce) {
    .layer { animation: none !important; }
    #stars { background-position: 0 0; }
  }
</style>
</head>
<body>
  <div class="layer" id="sector"></div>
  <div class="layer" id="nebula"></div>
  <div class="layer" id="stars"></div>
  <div class="layer" id="glitter"></div>
  <div id="vignette"></div>
</body>
</html>
"""


def main():
    default_out = os.path.expanduser(
        "~/Library/Application Support/LiveWallpaper/wallpapers/starbound-loading")
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=default_out, help="wallpaper folder to create")
    ap.add_argument("--pak", help="path to packed.pak (auto-detected if omitted)")
    args = ap.parse_args()

    out = os.path.expanduser(args.out)
    assets = os.path.join(out, "assets")
    os.makedirs(assets, exist_ok=True)

    pak = find_pak(args.pak)
    print(f"# pak: {pak}")
    by_path = {p: (o, s) for p, o, s in parse_index(pak)}

    with open(pak, "rb") as f:
        for _lid, pak_path, local in ASSETS:
            if pak_path not in by_path:
                sys.exit(f"asset missing from this Starbound build: {pak_path}")
            off, size = by_path[pak_path]
            f.seek(off)
            with open(os.path.join(assets, local), "wb") as g:
                g.write(f.read(size))
            print(f"  {size:>9} bytes  {pak_path} -> assets/{local}")

    index = os.path.join(out, "index.html")
    with open(index, "w") as g:
        g.write(HTML)
    print(f"# wallpaper written: {index}")


if __name__ == "__main__":
    main()
