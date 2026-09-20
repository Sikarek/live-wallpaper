// composite_pngs.swift — tiny CoreGraphics compositor used by the wallpaper builder tools.
//
// Why: Starbound's celestial horizon is a stack of same-size textures (base left+right, three surface
// masks that must be clipped to the planet, plus an atmosphere pass). Doing that in CSS leaves the mask
// silhouettes floating over the starfield; CoreGraphics does it properly with .sourceAtop.
//
// build: swiftc -O -o composite_pngs composite_pngs.swift
// run:   ./composite_pngs out.png <canvasW> <canvasH> \
//            --planet  base_l.png base_r.png \
//            --atop    mask1_l.png mask1_r.png mask2_l.png mask2_r.png ... \
//            --over    atmosphere_l.png atmosphere_r.png
//
// Pairs are centred horizontally and aligned to the bottom of the canvas.

import AppKit
import CoreGraphics

let argv = CommandLine.arguments
guard argv.count >= 5 else {
    FileHandle.standardError.write("usage: composite_pngs out.png W H [--planet l r] [--atop l r ...] [--over l r]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = argv[1]
guard let canvasW = Int(argv[2]), let canvasH = Int(argv[3]), canvasW > 0, canvasH > 0 else { exit(2) }

struct Group {
    var mode: CGBlendMode
    var alpha: CGFloat
    var files: [String]
    /// true: draw every file at the FULL canvas rect (stacked art, e.g. the 542x542 planet discs);
    /// false: butt the files together horizontally, bottom-aligned (the horizon band's left/right halves).
    var fullCanvas: Bool
}
var groups: [Group] = []
var index = 4
while index < argv.count {
    let flag = argv[index]
    index += 1
    // an optional alpha may follow the flag: --atop 0.18 mask1.png mask2.png
    var alpha: CGFloat = 1
    if index < argv.count, let value = Double(argv[index]), !argv[index].hasPrefix("--") {
        alpha = CGFloat(value)
        index += 1
    }
    var files: [String] = []
    while index < argv.count, !argv[index].hasPrefix("--") {
        files.append(argv[index])
        index += 1
    }
    let mode: CGBlendMode
    var full = false
    switch flag {
    case "--planet":   mode = .normal
    case "--atop":     mode = .sourceAtop
    case "--multiply": mode = .multiply
    case "--screen":   mode = .screen
    case "--over":     mode = .normal
    case "--stack":    mode = .normal; full = true          // same-size art drawn on top of itself
    default:
        FileHandle.standardError.write("unknown flag \(flag)\n".data(using: .utf8)!)
        exit(2)
    }
    groups.append(Group(mode: mode, alpha: alpha, files: files, fullCanvas: full))
}

func load(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return cg
}

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

for group in groups {
    ctx.setBlendMode(group.mode)
    ctx.setAlpha(group.alpha)
    if group.fullCanvas {
        for file in group.files {
            let image = load(file)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        }
        continue
    }
    var x = 0
    let totalWidth = group.files.reduce(0) { $0 + load($1).width }   // pairs butt together
    let startX = (canvasW - totalWidth) / 2
    for file in group.files {
        let image = load(file)
        // bottom-aligned; CG origin is bottom-left, so y = 0 is the bottom of the output PNG
        ctx.draw(image, in: CGRect(x: startX + x, y: 0, width: image.width, height: image.height))
        x += image.width
    }
}
ctx.setAlpha(1)

guard let result = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: result)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
print("ok: \(outPath) \(canvasW)x\(canvasH) \(data.count) bytes, \(groups.count) pass(es)")
