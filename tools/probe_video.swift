// probe_video.swift — print the format of a video file (codec, size, fps, duration, audio tracks).
// build: swiftc -O -o probe_video probe_video.swift      run: ./probe_video file.mov
import AVFoundation
import AppKit
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
// optional: --frame <seconds> --out <png> extracts a frame (proves the system decoder can decode it)
var frameTime: Double? = nil
var outPNG: String? = nil
if let i = CommandLine.arguments.firstIndex(of: "--frame"), i + 1 < CommandLine.arguments.count {
    frameTime = Double(CommandLine.arguments[i + 1])
}
if let i = CommandLine.arguments.firstIndex(of: "--out"), i + 1 < CommandLine.arguments.count {
    outPNG = CommandLine.arguments[i + 1]
}
guard !path.isEmpty else {
    FileHandle.standardError.write("usage: probe_video <file> [--frame <s> --out <png>]\n".data(using: .utf8)!)
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let sem = DispatchSemaphore(value: 0)

Task {
    do {
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("file      \(path)")
        print("size      \(String(format: "%.1f", Double(bytes ?? 0) / 1_000_000)) MB")
        print("duration  \(String(format: "%.2f", duration.seconds)) s")
        for track in tracks {
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            let formats = try await track.load(.formatDescriptions)
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            let type = track.mediaType == .video ? "video" : (track.mediaType == .audio ? "audio" : "other")
            if type == "video" {
                print("\(type)      \(Int(size.width))x\(Int(size.height))  \(String(format: "%.2f", rate)) fps  codec=\(codec)")
                if let format = formats.first {
                    let dims = CMVideoFormatDescriptionGetDimensions(format)
                    print("          profile/level \(profileName(format))  \(dims.width)x\(dims.height)")
                    if let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
                        let primaries = ext["ColorPrimaries" as String] ?? "?"
                        let transfer = ext["TransferFunction" as String] ?? "?"
                        let matrix = ext["YCbCrMatrix" as String] ?? "?"
                        let depth = ext["BitsPerComponent" as String] ?? "?"
                        let full = ext["FullRangeVideo" as String] ?? "?"
                        print("          color primaries=\(primaries) transfer=\(transfer) matrix=\(matrix)")
                        print("          bit depth=\(depth) fullRange=\(full)")
                        print("          raw extensions:")
                        for key in ext.keys.sorted() {
                            print("            \(key) = \(ext[key] ?? "?")")
                        }
                    }
                }
            } else {
                print("\(type)      codec=\(codec)")
            }
        }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    if let seconds = frameTime, let out = outPNG {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: out))
                print("frame     extracted ok at \(seconds)s -> \(out) (\(image.width)x\(image.height))")
            }
        } catch {
            print("frame     DECODE FAILED at \(seconds)s: \(error.localizedDescription)")
        }
    }
    sem.signal()
}
sem.wait()

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}

func profileName(_ format: CMFormatDescription) -> String {
    guard let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] else { return "?" }
    let profile = ext["ProfileLevel" as String].map { "\($0)" } ?? "?"
    return profile
}
