// mkloop.swift — turn a still image into a slow pan/zoom MP4 loop for use as a macOS wallpaper.
//
// build: swiftc -O -o mkloop mkloop.swift
// run:   ./mkloop in.png out.mp4 [seconds] [fps] [zoom]
//        e.g. ./mkloop jades_cutout.png loop.mp4 10 30 1.25
//
// Encodes H.264 through AVFoundation (hardware on Apple Silicon). No ffmpeg needed.

import AVFoundation
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else {
    FileHandle.standardError.write("usage: mkloop in.png out.mp4 [seconds] [fps] [zoom]\n".data(using: .utf8)!)
    exit(2)
}
let inPath = a[1], outPath = a[2]
let seconds = a.count > 3 ? (Double(a[3]) ?? 10) : 10
let fps     = a.count > 4 ? (Int(a[4]) ?? 30) : 30
let zoomEnd = a.count > 5 ? (Double(a[5]) ?? 1.25) : 1.25

guard let ns = NSImage(contentsOfFile: inPath),
      let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read image: \(inPath)\n".data(using: .utf8)!)
    exit(1)
}

// even dimensions (H.264 requirement)
let W = cg.width - (cg.width % 2)
let H = cg.height - (cg.height % 2)

try? FileManager.default.removeItem(atPath: outPath)
let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W,
    AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000,
                                      AVVideoMaxKeyFrameIntervalKey: 30]
])
input.expectsMediaDataInRealTime = false
guard writer.canAdd(input) else { exit(1) }
writer.add(input)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let space = CGColorSpaceCreateDeviceRGB()
let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: W,
                              kCVPixelBufferHeightKey: H,
                              kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
let total = max(1, Int(seconds * Double(fps)))

for f in 0..<total {
    var pbOut: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
          let pb = pbOut else { exit(1) }
    CVPixelBufferLockBaseAddress(pb, [])
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { exit(1) }

    // p goes 0 → 1 and back (seamless loop for a boomerang-style pan/zoom)
    let raw = Double(f) / Double(total)
    let p = raw < 0.5 ? raw * 2 : (1 - raw) * 2
    let z = 1.0 + (zoomEnd - 1.0) * p                    // zoom in
    let dw = Double(W) * z, dh = Double(H) * z
    let panX = (dw - Double(W)) * p * 0.6                // slow drift
    let panY = (dh - Double(H)) * (1 - p) * 0.3
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.draw(cg, in: CGRect(x: -panX, y: -panY, width: dw, height: dh))

    CVPixelBufferUnlockBaseAddress(pb, [])
    while !input.isReadyForMoreMediaData { usleep(2000) }
    if !adaptor.append(pb, withPresentationTime: CMTime(value: Int64(f), timescale: Int32(fps))) {
        FileHandle.standardError.write("append failed at frame \(f): \(String(describing: writer.error))\n".data(using: .utf8)!)
        exit(1)
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status == .completed {
    let sz = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
    print("ok: \(outPath) \(W)x\(H) \(total) frames @\(fps)fps \(sz) bytes")
} else {
    FileHandle.standardError.write("writer failed: \(String(describing: writer.error))\n".data(using: .utf8)!)
    exit(1)
}
