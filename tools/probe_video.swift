// probe_video.swift — print the format of a video file (codec, size, fps, duration, audio tracks).
// build: swiftc -O -o probe_video probe_video.swift      run: ./probe_video file.mov
import AVFoundation
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !path.isEmpty else {
    FileHandle.standardError.write("usage: probe_video <file>\n".data(using: .utf8)!)
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
            } else {
                print("\(type)      codec=\(codec)")
            }
        }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    sem.signal()
}
sem.wait()

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}
