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
import json as _json
import os
import random as _random
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

# Sky orbiters (the moons and the parent planet) — all from /sky.config + /celestial.config:
#   satellite.planetScale 3.0 / moonScale 1.5 / area [400,400]
#   a world's disc art is /celestial/system/terrestrial/biomes/<biome>/maskie<N>.png, 542x542 (measured),
#   stacked <baseCount>..1 and shaded by /celestial/system/terrestrial/shadows/<num>.png (shadowNumber 1-9)
#   the disc's on-screen size is texSize * imageScale * orbiterScale * pixelRatio, where imageScale comes
#   from the world's planetaryType (celestial.config planetaryTypes: Moon 0.125, terrestrial tiers 0.1/0.125)
DISC_DIR = "/celestial/system/terrestrial/biomes"
DISC_SHADOW_DIR = "/celestial/system/terrestrial/shadows"
DISC_LIQUID_DIR = "/celestial/system/terrestrial/liquids"
SATELLITE_AREA = (400.0, 400.0)       # sky.config satellite.area (view units)
MOON_SCALE = 1.5                      # sky.config satellite.moonScale
PARENT_SCALE = 3.0                    # sky.config satellite.planetScale
SHADOW_NUMBERS = 9                    # terrestrialGraphics.shadowNumber [1,9]
BASE_COUNT = {"garden": 5, "savannah": 4, "snow": 4, "toxic": 2}   # terrestrialGraphics baseCount
IMAGE_SCALE = {"moon": 0.125, "barren": 0.1}                       # planetaryTypes variationParameters
DEFAULT_IMAGE_SCALE = 0.1125          # terrestrial tiers 1-6 (0.1 / 0.125)
DISC_BIOMES = ["alien", "arctic", "barren", "desert", "forest", "garden", "jungle", "magma", "midnight",
               "moon", "ocean", "savannah", "scorchedcity", "snow", "toxic", "tundra", "volcanic"]
LIQUIDS = ["water", "lava", "poison", "swampwater", "tarliquid", "tentaclejuice"]

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
  cloudAlpha: __CLOUD_ALPHA__,        // 1.0 = the engine's alpha; the sprites are very faint
  orbiters: __ORBITERS__,             // sky moons + the parent planet, one entry per disc
  satelliteArea: [__AREA_W__, __AREA_H__],   // sky.config satellite.area
  imageScale: __IMAGE_SCALES__,       // per world type (celestial.config planetaryTypes)
  hueShift: __HUE_SHIFT__             // the biome's hueShift in degrees (0 = untouched)
};

var canvas = document.getElementById('sky');
var ctx = canvas.getContext('2d');
// Fixed origin (2025-01-01T00:00:00Z), not "the moment this page loaded": a reload or an app relaunch
// then continues the sky exactly where it was instead of snapping back to the start of the cycle.
var EPOCH_BASE = 1735689600000;
var W = 0, H = 0, DPR = 1;
var planetRatio = 1, pixelRatio = 1, view = { w: 0, h: 0 };
var horizonImage = new Image();
var cloudImages = [], starSheets = [], starFrameSize = [], orbiterImages = [];
var clouds = [], starTypes = [], starField = [];
var reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
// A web view that is not on screen (an offscreen preview, a hidden window, a test) never gets
// requestAnimationFrame callbacks, so the first frame would be drawn before the sprites finish loading
// and then never again. Redraw once whenever an image arrives, and remember the clock for it.
var started = false, forcedValue = null, lastSeconds = 0;

function scheduleRedraw() {
  if (!started) return;
  setTimeout(function () { frame(forcedValue !== null ? forcedValue : lastSeconds); }, 0);
}

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
  horizonImage.onload = scheduleRedraw;
  horizonImage.src = 'assets/horizon.png';
  for (var i = 0; i < __ORBITER_FILES__.length; i++) {
    var o = new Image(); o.onload = scheduleRedraw;
    o.src = 'assets/' + __ORBITER_FILES__[i]; orbiterImages.push(o);
  }
  for (var i = 0; i < __CLOUD_FILES__.length; i++) {
    var c = new Image(); c.onload = scheduleRedraw;
    c.src = 'assets/' + __CLOUD_FILES__[i]; cloudImages.push(c);
  }
  for (var s = 0; s < __STAR_FILES__.length; s++) {
    var img = new Image(); img.src = 'assets/' + __STAR_FILES__[s];
    starSheets.push(img);
    starFrameSize.push(null);           // measured once the sheet loads
    img.onload = (function (index, image) {
      return function () {
        starFrameSize[index] = [image.width / CFG.starFrames, image.height];
        scheduleRedraw();
      };
    })(s, img);
  }
}

// star field: built ONCE (the engine's Random2dPointGenerator) and then only transformed per frame.
// Re-hashing ~10k candidate cells every frame was what forced the 30 fps cap; the engine instead
// generates the field on a world-seed change and just draws it.
function buildStarField() {
  starField = [];
  var cell = CFG.starCellSize;
  var reach = Math.sqrt(view.w * view.w + view.h * view.h) / 2 + cell * 2;
  var cells = Math.ceil(reach / cell);
  var density = CFG.starCellCount;
  for (var gy = -cells; gy <= cells; gy++) {
    for (var gx = -cells; gx <= cells; gx++) {
      for (var k = 0; k < density; k++) {
        var fx = gx * cell + hash2(gx * 31 + k, gy * 17 + k, 5) * cell;
        var fy = gy * cell + hash2(gx * 13 + k, gy * 29 + k, 6) * cell;
        if (fx * fx + fy * fy > reach * reach) continue;          // keep a disc: covers any rotation
        starField.push({
          x: fx, y: fy,
          type: Math.floor(hash2(gx + k, gy - k, 8) * starSheets.length),
          offset: Math.floor(hash2(gx - k, gy + k, 9) * CFG.starFrames)
                  + lerp(CFG.twinkleMin, CFG.twinkleMax, hash2(gx, gy + k, 10))
        });
      }
    }
  }
}

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
  buildStarField();                                                     // regenerate for this view
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
// Positions are kept FRACTIONAL like the engine's Vec2F glyph positions (no rounding): at 60 fps a
// subpixel position is what makes a slow drift glide instead of stepping.
function drawStars(t, starRotation) {
  var cos = Math.cos(starRotation), sin = Math.sin(starRotation);
  var cx = view.w / 2, cy = view.h / 2;
  var frames = CFG.starFrames;
  ctx.imageSmoothingEnabled = true;                 // subpixel star sprites
  for (var i = 0; i < starField.length; i++) {
    var s = starField[i];
    var sx = cx + s.x * cos - s.y * sin;
    var sy = cy + s.x * sin + s.y * cos;
    if (sx < -8 || sx > view.w + 8 || sy < -8 || sy > view.h + 8) continue;

    var frame = Math.floor(t + s.offset) % frames;   // engine: (size_t)(epochTime + offset) % frames
    var size = starFrameSize[s.type];
    var px = sx * pixelRatio, py = sy * pixelRatio;  // screen px, still fractional
    if (size) {
      // the engine draws its star sprites 1:1 in DEVICE pixels, so on a Retina panel they must not
      // be 1:1 in CSS pixels or they come out ~2x too big next to the Lock Screen video
      var deviceScale = 1 / DPR;
      var sw = size[0] * deviceScale, sh = size[1] * deviceScale;
      ctx.drawImage(starSheets[s.type], frame * size[0], 0, size[0], size[1],
                    px - sw / 2, H - py - sh / 2, sw, sh);
    } else {
      dot(px, py, 1, 'rgba(255,255,255,0.9)');
    }
    window.__lwStarDrawn = (window.__lwStarDrawn || 0) + 1;
  }
  ctx.imageSmoothingEnabled = false;
}

// backOrbiters() (StarSkyRenderData.cpp:34-48): every moon and the parent planet is a disc whose
// position is (unit random * satellite.area), ROTATED WITH THE SKY about (viewW/2, 0) — the centre of
// the BOTTOM EDGE, not the planet centre the clouds orbit (that one sits 700 units below). The painter
// draws each disc centred on its position (RectF::withCenter) at texSize*scale*pixelRatio.
function drawOrbiters(starRotation) {
  window.__lwOrbitersDrawn = 0;
  window.__lwOrbiterInfo = [];
  if (!CFG.orbiters.length) return;
  var cos = Math.cos(starRotation), sin = Math.sin(starRotation);
  var cx = view.w / 2, cy = 0;
  var drawn = 0;
  for (var i = 0; i < CFG.orbiters.length; i++) {
    var o = CFG.orbiters[i];
    var img = orbiterImages[i];
    if (!img || !img.complete || !img.naturalWidth) continue;
    var dx = o.x * CFG.satelliteArea[0] - cx;
    var dy = o.y * CFG.satelliteArea[1] - cy;
    var x = cx + dx * cos - dy * sin;
    var y = cy + dx * sin + dy * cos;
    var scale = o.scale * (CFG.imageScale[o.type] || 0.1125) * pixelRatio;
    var w = img.naturalWidth * scale, h = img.naturalHeight * scale;
    var px = x * pixelRatio, py = y * pixelRatio;      // px from the bottom edge
    if (px + w / 2 < 0 || px - w / 2 > W) continue;    // off-screen sideways
    if (py + h / 2 < 0 || py - h / 2 > H) continue;    // fully below the bottom edge / above the top
    image(px - w / 2, py - h / 2, w, h, img);
    drawn++;
    window.__lwOrbiterInfo.push({ type: o.type, x: Math.round(px), y: Math.round(py),
                                  size: Math.round(w) });
  }
  window.__lwOrbitersDrawn = drawn;
}

function drawPlanet() {
  if (!horizonImage.complete || !horizonImage.naturalWidth) return;
  var w = horizonImage.naturalWidth * planetRatio;
  var h = horizonImage.naturalHeight * planetRatio;
  // the engine's biome hueShift rides on the base image (celestial.config: "?hueshift=")
  if (CFG.hueShift) ctx.filter = 'hue-rotate(' + CFG.hueShift + 'deg)';
  image((W - w) / 2, 0, w, h, horizonImage);        // centred on the view, sitting on the bottom edge
  ctx.filter = 'none';
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
  lastSeconds = seconds;
  started = true;
  var day = seconds % CFG.dayLength;
  var starRotation = 2 * Math.PI * day / CFG.dayLength;    // StarSky.cpp:204 (2pi wrap is seamless
                                                           // for a random field, so no jump)
  var orbitAngle = 2 * Math.PI * seconds / CFG.dayLength;   // NOT wrapped: cloud speeds are
                                                            // fractional, so wrapping would make the
                                                            // clouds jump once per day
  var t = seconds;

  window.__lwStarDrawn = 0;
  drawSky();
  drawStars(t, starRotation);
  drawOrbiters(starRotation);                        // engine order: stars -> debris -> back orbiters
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
      frames: frame.count,
      starsDrawn: window.__lwStarCount || 0,
      clouds: clouds.length,
      cloudsDrawn: window.__lwCloudsDrawn || 0,
      orbiters: window.__lwOrbiterInfo || [],
      orbitersDrawn: window.__lwOrbitersDrawn || 0,
      frameMs: (window.__lwFrameStats ? window.__lwFrameStats().medianMs : null),
      fps: (window.__lwFrameStats ? window.__lwFrameStats().fps : null),
      frames: (window.__lwFrameStats ? window.__lwFrameStats().frames : null),
      cloudState: cloudImages.map(function (i) { return (i.complete ? 'done' : 'loading') + ':' + i.naturalWidth; }).join(' '),
      horizonWidth: horizonImage.naturalWidth,
      starWidths: starSheets.map(function (i) { return i.naturalWidth; }).join(','),
      cloudHash: window.__lwCloudHash || 0,
      w: W, h: H
    });
  };

  function currentSeconds() { return (Date.now() - EPOCH_BASE) / 1000; }

  forcedValue = forced !== null ? parseFloat(forced) : null;   // module-level: scheduleRedraw needs it
  started = true;            // from here on, a late-loading sprite triggers a redraw

  // ?t= renders a fixed moment for the tests. Keep redrawing it: sprites load asynchronously, so a
  // single early draw would capture an empty scene.
  if (reduceMotion) {
    var stillTime = forcedValue !== null ? forcedValue : currentSeconds();
    frame(stillTime);
    setInterval(function () { frame(stillTime); }, 250);
    return;
  }

  // -------------------------------------------------------------------------------------------
  // The game's loop, which is where the smoothness comes from:
  //   * TickRateApproacher(60.0) -- the sky is advanced in FIXED 1/60 s steps, not by whatever the
  //     frame delta happened to be, and the ticker catches up if a frame ran long.
  //   * VSync presentation -- one drawn frame per display refresh.
  //   * Sky::m_time += dt -- a monotonic double accumulator, never a wall-clock lookup, so external
  //     clock changes cannot make the scene jump.
  // Everything drawn is then a pure linear function of that time (no easing, no keyframes, no
  // restarts), which is what makes it read as perfectly smooth rather than "animated".
  // -------------------------------------------------------------------------------------------
  var STEP = 1 / 60;
  var skyTime = currentSeconds();              // absolute phase: a reload continues where it was
  var lastNow = performance.now();
  var accumulator = 0;
  var frameDeltas = [];
  var drawnFrames = 0;

  (function loop(now) {
    var delta = (now - lastNow) / 1000;
    lastNow = now;
    if (delta > 0.25 || delta < 0) {           // after display sleep/suspend: resume, don't fast-forward
      delta = STEP;
      accumulator = 0;
    }
    accumulator += delta;
    var steps = 0;
    while (accumulator >= STEP && steps < 60) { skyTime += STEP; accumulator -= STEP; steps++; }
    if (frameDeltas.length < 240) frameDeltas.push(delta * 1000);
    drawnFrames++;
    frame(forcedValue !== null ? forcedValue : skyTime);
    window.__lwFrameStats = function () {
      var sorted = frameDeltas.slice().sort(function (a, b) { return a - b; });
      var median = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
      return {
        frames: drawnFrames,
        medianMs: Math.round(median * 100) / 100,
        p95Ms: sorted.length ? Math.round(sorted[Math.floor(sorted.length * 0.95)] * 100) / 100 : 0,
        fps: median > 0 ? Math.round(1000 / median) : 0
      };
    };
    requestAnimationFrame(loop);
  })(lastNow);
}

start();
</script>
</body>
</html>
"""


def png_size(path):
    """(w, h) straight from the PNG header — the disc art's size decides the canvas here."""
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"not a PNG: {path}")
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def ensure_compositor():
    """Compile tools/composite_pngs.swift on first use (swiftc ships with the Command Line Tools).

    LW_COMPOSITOR points at a prebuilt binary — an app bundle ships one, so nothing is compiled and the
    bundle can stay read-only."""
    prebuilt = os.environ.get("LW_COMPOSITOR")
    if prebuilt:
        if os.path.exists(prebuilt):
            return prebuilt
        sys.exit(f"LW_COMPOSITOR is set to {prebuilt} but there is nothing there")
    here = os.path.dirname(os.path.abspath(__file__))
    cache = os.path.expanduser("~/Library/Caches/LiveWallpaper")
    binary = os.path.join(cache, "composite_pngs")
    source = os.path.join(here, "composite_pngs.swift")
    if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
        os.makedirs(cache, exist_ok=True)
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
    ap.add_argument("--moons", type=int, default=0, choices=[0, 1, 2, 3],
                    help="how many moons share the sky (the engine draws every sibling satellite)")
    ap.add_argument("--moon-types", default="",
                    help="comma list of biome names for the moons, e.g. moon,tundra,barren "
                         "(default: picked from the seed)")
    ap.add_argument("--parent-planet", default="none",
                    help="draw the planet you orbit in the sky (the engine does this when the world "
                         "is a moon): any biome name, or none")
    ap.add_argument("--moon-size", type=float, default=1.0,
                    help="multiplier on the engine's moonScale (scene units, default 1.0)")
    ap.add_argument("--planet-size", type=float, default=1.0,
                    help="multiplier on the engine's planetScale")
    ap.add_argument("--disc-shadow", type=int, default=0,
                    help="which shadow sprite (1-9) the moon/planet discs use; 0 = from the seed")
    ap.add_argument("--liquid", default="none",
                    help="surface liquid as the horizon's base image: " + ", ".join(LIQUIDS) + ", or none")
    ap.add_argument("--hue-shift", type=float, default=0.0,
                    help="hue rotation in degrees applied to the base image (the engine's biome hueShift)")
    ap.add_argument("--dump-options", action="store_true",
                    help="print the palette of choices as JSON (the Composer app builds its pickers "
                         "from this, so the two can never drift apart) and exit")
    args = ap.parse_args()

    if args.dump_options:
        print(_json.dumps({
            "planets": DISC_BIOMES,
            "liquids": LIQUIDS,
            "masks": list(range(1, 26)),
            "maskPerPlanet": {"garden": [3, 3], "forest": [3, 3], "savannah": [3, 3], "jungle": [3, 3],
                              "alien": [3, 3], "volcanic": [3, 3], "scorchedcity": [2, 3], "toxic": [2, 2],
                              "ocean": [1, 2], "arctic": [1, 2], "magma": [1, 2]},
            "shadows": list(range(1, SHADOW_NUMBERS + 1)),
            "moonScale": MOON_SCALE, "planetScale": PARENT_SCALE,
            "imageScale": {**{"default": DEFAULT_IMAGE_SCALE}, **IMAGE_SCALE},
            "satelliteArea": list(SATELLITE_AREA),
            "defaults": {"planet": "garden", "masks": [int(m) for m in DEFAULT_MASKS], "maskAlpha": 0.18,
                         "dayLength": 600.0, "cloudAlpha": 3.0, "starsPerCell": STAR_CELL_COUNT,
                         "seed": 1234567},
        }, indent=2))
        return

    out = os.path.expanduser(args.out)
    assets = os.path.join(out, "assets")
    os.makedirs(os.path.join(assets, "stars"), exist_ok=True)

    masks = [m.strip() for m in args.masks.split(",") if m.strip()]
    mask_dir = "temperate"
    liquid = args.liquid if args.liquid in LIQUIDS else None

    # ---- the sky's other bodies: the moons and (optionally) the planet we orbit ------------------
    rng = _random.Random(args.seed)
    orbiters = []
    if args.parent_planet and args.parent_planet != "none":
        if args.parent_planet not in DISC_BIOMES:
            sys.exit(f"unknown --parent-planet {args.parent_planet!r}; pick one of: {', '.join(DISC_BIOMES)}")
        orbiters.append({"type": args.parent_planet, "scale": round(PARENT_SCALE * args.planet_size, 4),
                         "parent": True})
    moon_types = [t.strip() for t in args.moon_types.split(",") if t.strip()]
    for i in range(args.moons):
        t = moon_types[i] if i < len(moon_types) else rng.choice(DISC_BIOMES)
        if t not in DISC_BIOMES:
            sys.exit(f"unknown moon type {t!r}; pick one of: {', '.join(DISC_BIOMES)}")
        orbiters.append({"type": t, "scale": round(MOON_SCALE * args.moon_size, 4), "parent": False})
    disc_sources = []          # (pak path, local path) pairs for the compositor's inputs
    for i, orbiter in enumerate(orbiters):
        orbiter["x"] = round(rng.random(), 6)          # unit random x satellite.area, like the engine
        orbiter["y"] = round(rng.random(), 6)
        orbiter["image"] = f"disc{i}.png"
        shadow = args.disc_shadow or rng.randint(1, SHADOW_NUMBERS)
        stack = []
        if liquid:
            stack.append(f"{DISC_LIQUID_DIR}/{liquid}.png")
        for n in range(BASE_COUNT.get(orbiter["type"], 3), 0, -1):
            stack.append(f"{DISC_DIR}/{orbiter['type']}/maskie{n}.png")
        stack.append(f"{DISC_SHADOW_DIR}/{shadow}.png")
        orbiter["stack"] = [os.path.join(f"discsrc{i}", os.path.basename(p)) for p in stack]
        for p, local in zip(stack, orbiter["stack"]):
            disc_sources.append((p, local))

    wanted = [
        (f"{HORIZON}/textures/{args.planet}_l.png", f"{args.planet}_l.png"),
        (f"{HORIZON}/textures/{args.planet}_r.png", f"{args.planet}_r.png"),
        (f"{HORIZON}/atmosphere/atmosphere_l.png", "atmosphere_l.png"),
        (f"{HORIZON}/atmosphere/atmosphere_r.png", "atmosphere_r.png"),
        (f"{HORIZON}/shadow/shadow_l.png", "shadow_l.png"),
        (f"{HORIZON}/shadow/shadow_r.png", "shadow_r.png"),
    ]
    if liquid:
        wanted.append((f"{HORIZON}/liquids/{liquid}_l.png", "liquid_l.png"))
        wanted.append((f"{HORIZON}/liquids/{liquid}_r.png", "liquid_r.png"))
    wanted += disc_sources
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
            dest = os.path.join(assets, local)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as g:
                g.write(f.read(size))
    print(f"# extracted {len(wanted)} assets ({len(STAR_SHEETS)} star sheets, {len(CLOUD_SHEETS)} clouds, "
          f"{len(orbiters)} disc stack(s))")

    # Composite the celestial stack the way the engine does. Two shapes, from worldHorizonImages():
    #   dry world   : base = <biome>_l|r  (+ the surface masks, this build's own tuning)
    #   liquid world: base = the LIQUID, and the biome rides ON TOP of it clipped to the masks
    #                 (celestial.config: "liquidTextures" then baseImages with "?addmask=<masks>"),
    #                 which is what puts landmasses in the sea instead of a flat ocean.
    # Then the shadow pass, then the atmosphere.
    compositor = ensure_compositor()
    horizon = os.path.join(assets, "horizon.png")
    def mask_passes(flag, alpha=None):
        """One pass PER mask pair, all at the same rect.

        The engine adds the whole mask list at offset {0,0} (AlphaMaskImageOperation{Additive, masks,
        {0,0}}), i.e. the masks STACK. Passing all six files to a single pass butts them side by side
        instead, and with a 1764-wide canvas only the middle pair survives — which silently turned
        "3 masks" into "1 mask" in every wallpaper built before this."""
        passes = []
        for m in masks:
            passes += [flag] + ([str(alpha)] if alpha is not None else []) + [f"mask{m}_l.png", f"mask{m}_r.png"]
        return passes

    if liquid:
        landmass = os.path.join(assets, "landmass.png")
        plate = [compositor, landmass, "1764", "202"]
        if masks:
            plate += mask_passes("--over")                                     # the landmass shapes
            plate += ["--atop", "1.0", f"{args.planet}_l.png", f"{args.planet}_r.png"]   # biome only there
        else:
            plate += ["--over", f"{args.planet}_l.png", f"{args.planet}_r.png"]          # all land, no sea
        print("  " + subprocess.run(plate, capture_output=True, text=True, cwd=assets).stdout.strip())
        # The engine draws the biome layer over the liquid at FULL strength: the mask is only the alpha
        # channel of that layer, never a transparency knob. Damping it is what made every ocean world
        # read as water with a hint of land.
        cmd = [compositor, horizon, "1764", "202", "--planet", "liquid_l.png", "liquid_r.png",
               "--over", "landmass.png"]
        if args.shade:
            cmd += ["--multiply", "0.45", "shadow_l.png", "shadow_r.png"]
    else:
        # the dry-world pass order is unchanged from the build that produced the shipped wallpaper
        # (base -> shadow -> masks): keep it byte-for-byte instead of "tidying" the look.
        cmd = [compositor, horizon, "1764", "202", "--planet",
               f"{args.planet}_l.png", f"{args.planet}_r.png"]
        if args.shade:
            cmd += ["--multiply", "0.45", "shadow_l.png", "shadow_r.png"]
        if masks:
            cmd += mask_passes("--atop", args.mask_alpha)
    cmd += ["--screen", "atmosphere_l.png", "atmosphere_r.png"]
    print("  " + subprocess.run(cmd, capture_output=True, text=True, cwd=assets).stdout.strip())

    # Composite each sky body the way drawWorld() stacks it: the disc art <baseCount>..1, then the
    # shadow sprite on top. All layers are the same 542x542 texture, so they draw at the same rect.
    for orbiter in orbiters:
        size = png_size(os.path.join(assets, orbiter["stack"][0]))
        cmd = [compositor, os.path.join(assets, orbiter["image"]), str(size[0]), str(size[1]),
               "--stack"] + orbiter["stack"]
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
            .replace("__ORBITERS__", _json.dumps([{"x": o["x"], "y": o["y"], "type": o["type"],
                                                   "scale": o["scale"]} for o in orbiters]))
            .replace("__AREA_W__", str(SATELLITE_AREA[0])).replace("__AREA_H__", str(SATELLITE_AREA[1]))
            .replace("__IMAGE_SCALES__", _json.dumps({**{"default": DEFAULT_IMAGE_SCALE}, **IMAGE_SCALE}))
            .replace("__HUE_SHIFT__", str(args.hue_shift))
            .replace("__ORBITER_FILES__", repr([o["image"] for o in orbiters]))
            .replace("__CLOUD_FILES__", repr([f"{c}.png" for c in CLOUD_SHEETS]))
            .replace("__STAR_FILES__", repr([f"stars/{s}_star.png" for s in STAR_SHEETS])))

    index = os.path.join(out, "index.html")
    with open(index, "w") as g:
        g.write(html)

    # The wallpaper documents how it was made: the Composer reads nothing from this, the tests do, and
    # it is what tells you (months later) which moons and which masks produced a look you liked.
    plan = {
        "generator": "starbound_mainmenu.py",
        "planet": args.planet, "masks": masks, "maskAlpha": args.mask_alpha, "shade": bool(args.shade),
        "liquid": liquid, "hueShift": args.hue_shift, "dayLength": args.day_length,
        "cloudAlpha": args.cloud_alpha, "starsPerCell": args.stars_per_cell, "seed": args.seed,
        "interfaceScale": args.interface_scale,
        "engine": {"satelliteArea": list(SATELLITE_AREA), "moonScale": args.moon_size * MOON_SCALE,
                   "planetScale": args.planet_size * PARENT_SCALE,
                   "imageScale": {**{"default": DEFAULT_IMAGE_SCALE}, **IMAGE_SCALE}},
        "orbiters": [{"x": o["x"], "y": o["y"], "type": o["type"], "scale": o["scale"],
                      "image": o["image"]} for o in orbiters],
    }
    with open(os.path.join(out, "backdrop.json"), "w") as g:
        _json.dump(plan, g, indent=2)
    print(f"# wallpaper written: {index}")
    print(f"# planet={args.planet} masks={masks} dayLength={args.day_length}s stars/cell={args.stars_per_cell} "
          f"moons={args.moons} parent={args.parent_planet}")


if __name__ == "__main__":
    main()
