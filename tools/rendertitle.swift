// rendertitle.swift — render the Starbound title-screen scene to a looping .mov, for the macOS
// Lock Screen (macOS 26+ plays an app-provided video there through the system "aerial" slot; the
// lock screen cannot run live content, so the same scene is baked into a video).
//
// It replays exactly the renderer that the HTML wallpaper runs (same seed, same hash, same numbers
// from the game's /sky.config), so the Lock Screen and the desktop show the same sky, in the same
// phase at the same wall-clock moment.
//
// build: swiftc -O -o rendertitle rendertitle.swift
// run:   ./rendertitle out.mov <assets-dir> [--width 1920] [--height 1080] [--fps 30]
//                          [--encode-fps 240] [--seconds 180] [--seed 1234567] [--codec hevc]
//
// The output deliberately matches Apple's own aerial encoding, because that is what the system's
// wallpaper extension is built to play:
//   * the manifest entry for an aerial is literally keyed "url-4K-SDR-240FPS"
//   * Apple's files here are 3840x2160, hvc1, 10 bit, 239.76 fps, Rec.709 primaries with sRGB
//     transfer, no audio
// So: 10-bit HEVC, Rec.709/sRGB tags, and 240 fps. The 240 fps is produced by repeating each
// rendered frame (--fps) 8 times, which costs almost nothing in file size (identical frames) but
// gives the player the timebase it expects.
//
// Seamless loop: the star field completes exactly one revolution over --seconds, and a random field
// rotated by 2*pi is identical, so the loop point is invisible. The faint horizon clouds keep the
// game's own speeds (0.2..0.3 orbit per day) and therefore do not return to their start; at ~7%
// alpha that discontinuity is not visible.

import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import VideoToolbox

// MARK: - the game's numbers (/sky.config), matching the HTML wallpaper

let STAR_SHEETS = ["bigb", "bigr", "bigw", "bigy", "mediumb", "smallerw", "smallr", "smallw", "smally", "transw"]
let STAR_FRAMES = 4
let STAR_CELL_SIZE = 180.0
let TWINKLE_MIN = 1.0, TWINKLE_MAX = 2.5
let PLANET_SCALE = 0.5
let Y_CENTER = -700.0
let CLOUD_COUNT = 30...60
let CLOUD_RADIUS = 740.0...810.0
let CLOUD_SPEED = 0.2...0.3
let CLOUD_SHEETS = ["cloud2", "cloud3", "cloud4"]
let DARKEN = 0.39
let INTERFACE_SCALE = 1.0

// MARK: - args

var outPath = ""
var assetsDir = ""
var width = 1920, height = 1080
var fps = 30
var encodeFps = 240
var seconds = 180.0
var seed: Int32 = 1234567
var starsPerCell = 80
var codec = "hevc"

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--width" where i + 1 < argv.count: width = Int(argv[i + 1]) ?? width; i += 2
    case "--height" where i + 1 < argv.count: height = Int(argv[i + 1]) ?? height; i += 2
    case "--fps" where i + 1 < argv.count: fps = Int(argv[i + 1]) ?? fps; i += 2
    case "--encode-fps" where i + 1 < argv.count: encodeFps = Int(argv[i + 1]) ?? encodeFps; i += 2
    case "--seconds" where i + 1 < argv.count: seconds = Double(argv[i + 1]) ?? seconds; i += 2
    case "--seed" where i + 1 < argv.count: seed = Int32(argv[i + 1]) ?? seed; i += 2
    case "--stars-per-cell" where i + 1 < argv.count: starsPerCell = Int(argv[i + 1]) ?? starsPerCell; i += 2
    case "--codec" where i + 1 < argv.count: codec = argv[i + 1]; i += 2
    default:
        if outPath.isEmpty { outPath = argv[i] } else if assetsDir.isEmpty { assetsDir = argv[i] }
        i += 1
    }
}
guard !outPath.isEmpty, !assetsDir.isEmpty else {
    FileHandle.standardError.write("usage: rendertitle out.mov <assets-dir> [options]\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - the same 32-bit hash the HTML wallpaper uses (must match exactly)

func hash2(_ x: Int, _ y: Int, _ salt: Int) -> Double {
    var h = UInt32(bitPattern: seed)   // seeded from the world seed, like the engine
    h ^= UInt32(bitPattern: Int32(truncatingIfNeeded: x)) &* 0x27d4eb2d
    h ^= UInt32(bitPattern: Int32(truncatingIfNeeded: y)) &* 0x165667b1
    h ^= UInt32(bitPattern: Int32(truncatingIfNeeded: salt)) &* 0x9e3779b1
    h ^= h >> 15; h = h &* 0x85ebca6b
    h ^= h >> 13; h = h &* 0xc2b2ae35
    h ^= h >> 16
    return Double(h) / 4294967296.0
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - assets

func loadImage(_ path: String) -> CGImage? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

let horizon = loadImage("\(assetsDir)/horizon.png")
let clouds = CLOUD_SHEETS.compactMap { loadImage("\(assetsDir)/\($0).png") }
let starSheets = STAR_SHEETS.compactMap { loadImage("\(assetsDir)/stars/\($0)_star.png") }
guard let planet = horizon, !starSheets.isEmpty else {
    FileHandle.standardError.write("missing assets in \(assetsDir)\n".data(using: .utf8)!)
    exit(1)
}
print("assets: planet \(planet.width)x\(planet.height), \(starSheets.count) star sheets, \(clouds.count) clouds")

// MARK: - layout (StarTitleScreen.cpp ratios)

let pixelRatio = lerp(0.125, Double(height) / 1080.0 * 3.0, INTERFACE_SCALE)   // orbiterAndPlanetRatio
let planetRatio = pixelRatio * PLANET_SCALE
let viewW = Double(width) / pixelRatio
let viewH = Double(height) / pixelRatio

struct Star { let x: Double, y: Double, type: Int, offset: Double }
var field: [Star] = []
do {
    let cell = STAR_CELL_SIZE
    let reach = (viewW * viewW + viewH * viewH).squareRoot() / 2 + cell * 2
    let cells = Int((reach / cell).rounded(.up))
    for gy in -cells...cells {
        for gx in -cells...cells {
            for k in 0..<starsPerCell {
                let fx = Double(gx) * cell + hash2(gx * 31 + k, gy * 17 + k, 5) * cell
                let fy = Double(gy) * cell + hash2(gx * 13 + k, gy * 29 + k, 6) * cell
                if fx * fx + fy * fy > reach * reach { continue }
                field.append(Star(x: fx, y: fy,
                                  type: Int(hash2(gx + k, gy - k, 8) * Double(starSheets.count)),
                                  offset: (hash2(gx - k, gy + k, 9) * Double(STAR_FRAMES)).rounded(.down)
                                          + lerp(TWINKLE_MIN, TWINKLE_MAX, hash2(gx, gy + k, 10))))
            }
        }
    }
}
print("star field: \(field.count) candidates, drawing ~\(Int(Double(field.count) * 0.2)) per frame")

struct Cloud { let startAngle: Double, image: Int, speed: Double, radius: Double }
var cloudList: [Cloud] = []
do {
    let count = Int(lerp(Double(CLOUD_COUNT.lowerBound), Double(CLOUD_COUNT.upperBound), hash2(1, 1, 7)).rounded())
    for c in 0..<count {
        cloudList.append(Cloud(startAngle: hash2(c, 11, 1) * .pi * 2,
                               image: c % max(clouds.count, 1),
                               speed: lerp(CLOUD_SPEED.lowerBound, CLOUD_SPEED.upperBound, hash2(c, 12, 2)),
                               radius: lerp(CLOUD_RADIUS.lowerBound, CLOUD_RADIUS.upperBound, hash2(c, 13, 3))))
    }
}
print("clouds: \(cloudList.count)")

// fixed origin, matching the HTML wallpaper: the same wall-clock moment gives the same phase
let EPOCH_BASE = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01T00:00:00Z

// MARK: - writer

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
var compression: [String: Any] = [
    AVVideoAverageBitRateKey: codec == "h264" ? 12_000_000 : 9_000_000,
    AVVideoMaxKeyFrameIntervalKey: encodeFps * 2
]
if codec != "h264" {
    compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel   // 10-bit, like Apple's
}
var settings: [String: Any] = [
    AVVideoCodecKey: codec == "h264" ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: compression,
    // Apple's aerials are Rec.709 primaries with an sRGB transfer function (SDR)
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false

// Pick a pixel format that CoreGraphics can draw 10-bit into, so no conversion happens on the way to
// the encoder. Falls back to 8-bit BGRA if none of them is available.
struct PixelFormat { let type: OSType, bitmapInfo: UInt32, name: String }
let candidates = [
    PixelFormat(type: kCVPixelFormatType_64ARGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder16Big.rawValue,
                name: "64ARGB (16bpc)"),
    PixelFormat(type: kCVPixelFormatType_32BGRA,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
                name: "32BGRA (8bpc)")
]
var chosen: PixelFormat?
for candidate in candidates {
    var probe: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: 64, kCVPixelBufferHeightKey: 64,
                                  kCVPixelBufferPixelFormatTypeKey: candidate.type]
    guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, candidate.type, attrs as CFDictionary, &probe) == kCVReturnSuccess,
          let buffer = probe else { continue }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ok = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 64, height: 64,
                       bitsPerComponent: candidate.type == kCVPixelFormatType_64ARGB ? 16 : 8,
                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: candidate.bitmapInfo) != nil
    CVPixelBufferUnlockBaseAddress(buffer, [])
    if ok { chosen = candidate; break }
}
guard let format = chosen else {
    FileHandle.standardError.write("no usable pixel format\n".data(using: .utf8)!)
    exit(1)
}
print("pixel format: \(format.name)")

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: format.type,
                                  kCVPixelBufferWidthKey as String: width,
                                  kCVPixelBufferHeightKey as String: height])
guard writer.canAdd(input) else { exit(1) }
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                   kCVPixelBufferPixelFormatTypeKey: format.type]

// MARK: - draw one frame

func drawFrame(context ctx: CGContext, time t: Double) {
    let dayLength = seconds                       // one full star revolution per loop
    let day = t.truncatingRemainder(dividingBy: dayLength)
    let starRotation = 2 * Double.pi * day / dayLength
    let orbitAngle = 2 * Double.pi * t / dayLength

    // sky
    ctx.setFillColor(CGColor(red: 0.024, green: 0.031, blue: 0.059, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // stars: rotate the field about the view centre, draw at fractional positions
    let cosR = cos(starRotation), sinR = sin(starRotation)
    let cx = viewW / 2, cy = viewH / 2
    ctx.setShouldAntialias(false)
    for star in field {
        let sx = cx + star.x * cosR - star.y * sinR
        let sy = cy + star.x * sinR + star.y * cosR
        if sx < -8 || sx > viewW + 8 || sy < -8 || sy > viewH + 8 { continue }
        let frame = Int((t + star.offset).rounded(.down)) % STAR_FRAMES
        let sheet = starSheets[star.type]
        guard let cropped = sheet.cropping(to: CGRect(x: frame * (sheet.width / STAR_FRAMES), y: 0,
                                                     width: sheet.width / STAR_FRAMES, height: sheet.height))
        else { continue }
        let px = sx * pixelRatio, py = sy * pixelRatio
        ctx.draw(cropped, in: CGRect(x: px - Double(cropped.width) / 2,
                                     y: Double(height) - py - Double(cropped.height) / 2,
                                     width: Double(cropped.width), height: Double(cropped.height)))
    }
    ctx.setShouldAntialias(true)

    // planet (nearest-neighbour like the engine: crisp pixel-art limb)
    let pw = Double(planet.width) * planetRatio, ph = Double(planet.height) * planetRatio
    ctx.interpolationQuality = .none
    ctx.draw(planet, in: CGRect(x: (Double(width) - pw) / 2, y: 0, width: pw, height: ph))

    // horizon clouds
    for cloud in cloudList {
        let a = cloud.startAngle + orbitAngle * cloud.speed
        let x = cos(a) * cloud.radius + cx
        let y = sin(a) * cloud.radius + Y_CENTER
        if y < -80 { continue }
        let image = clouds[cloud.image]
        let cw = Double(image.width) * planetRatio, ch = Double(image.height) * planetRatio
        ctx.setBlendMode(.screen)
        ctx.draw(image, in: CGRect(x: x * pixelRatio - cw / 2,
                                   y: Double(height) - y * pixelRatio - ch / 2,
                                   width: cw, height: ch))
        ctx.setBlendMode(.normal)
    }

    // title.config skyBackdropDarken
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: DARKEN))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
}

// MARK: - render

let start = Date()
let base = EPOCH_BASE.timeIntervalSinceNow * -1        // seconds since the fixed origin, now
let duplicate = max(1, encodeFps / fps)                // 30 -> 240 fps = each frame appended 8x
let uniqueFrames = Int(seconds * Double(fps))
print("rendering \(uniqueFrames) frames, encoding \(uniqueFrames * duplicate) @\(encodeFps)fps")

for frame in 0..<uniqueFrames {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.type,
                              attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let pixelBuffer = buffer else { exit(1) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                           bitsPerComponent: format.type == kCVPixelFormatType_64ARGB ? 16 : 8,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                           space: colorSpace, bitmapInfo: format.bitmapInfo) {
        // the video's own phase must line up with the wallpaper's: same origin, one revolution per loop
        drawFrame(context: ctx, time: base + Double(frame) / Double(fps))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    // repeat the frame to reach the player's expected 240 fps timebase
    for copy in 0..<duplicate {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        let pts = CMTime(value: Int64(frame * duplicate + copy), timescale: Int32(encodeFps))
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            FileHandle.standardError.write("append failed at \(frame)/\(copy): \(String(describing: writer.error))\n".data(using: .utf8)!)
            exit(1)
        }
    }
    if frame % (fps * 10) == 0 {
        let done = Double(frame) / Double(uniqueFrames) * 100
        print(String(format: "  %5.1f%%  frame %d/%d  (%.0fs elapsed)", done, frame, uniqueFrames,
                     Date().timeIntervalSince(start)))
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status == .completed {
    let size = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
    print(String(format: "done: %@  %dx%d %d frames @%dfps  %.1f MB  in %.0fs",
                 outPath, width, height, uniqueFrames * duplicate, encodeFps, Double(size) / 1_000_000,
                 Date().timeIntervalSince(start)))
} else {
    FileHandle.standardError.write("writer failed: \(String(describing: writer.error))\n".data(using: .utf8)!)
    exit(1)
}
