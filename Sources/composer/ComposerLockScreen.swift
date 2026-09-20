// ComposerLockScreen.swift — the Lock Screen is a video, not a web page, so a combination only reaches
// it by being rendered to a file and installed into Apple's aerial slot. Same plan, same day length,
// same moons: the renderer reads backdrop.json, so the two sides cannot drift.

import Foundation

extension Composer {

    static let lockScreenDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LiveWallpaper/lockscreen", isDirectory: true)

    /// What is in the aerial slot right now, and whether it matches this combination. The probe runs
    /// AVFoundation and can be slow while a 4K render is eating the machine, so retry once before
    /// reporting an unknown duration.
    func lockScreenStatus() -> String {
        guard let tool = Tools.lockscreenTool else { return "lockscreen.py not found" }
        var result = Tools.run(tool, arguments: ["--rates"])
        if let text = result?.out, text.contains("duration ?") || text.isEmpty {
            Thread.sleep(forTimeInterval: 1.0)
            result = Tools.run(tool, arguments: ["--rates"]) ?? result
        }
        guard let result else { return "could not read the slot" }
        return Tools.slotStatusLine(result.out)
    }

    /// Render this combination to a video and put it in the aerial slot.
    /// 4K/240 fps is a real encode (minutes, not seconds), so progress is reported as it goes.
    func renderForLockScreen(completion: (() -> Void)? = nil) {
        guard let renderer = Tools.renderTitle, let installer = Tools.lockscreenTool else {
            status = "rendertitle/lockscreen.py not found — run build.sh"
            completion?(); return
        }
        let folder = Self.libraryDir.appendingPathComponent(safeName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("backdrop.json").path) else {
            status = "export this combination first — the renderer needs its backdrop.json"
            completion?(); return
        }
        try? FileManager.default.createDirectory(at: Self.lockScreenDir, withIntermediateDirectories: true)
        // render to a temporary name and only publish "<name>.mov" when it is complete: the wallpaper
        // app watches for "<name>.mov" and would otherwise try to install a half-written file
        let movie = Self.lockScreenDir.appendingPathComponent("\(safeName).mov")
        let partial = Self.lockScreenDir.appendingPathComponent("\(safeName).rendering.mov")
        try? FileManager.default.removeItem(at: partial)

        busy = true
        status = "rendering the Lock Screen clip at \(Int(dayLength))s (4K, this takes a while)…"
        let dayLength = Int(dayLength)
        DispatchQueue.global(qos: .userInitiated).async {
            Tools.runStreaming(executable: renderer,
                               arguments: [partial.path, folder.path, "--width", "3840", "--height", "2160",
                                           "--fps", "15", "--encode-fps", "240"]) { line in
                if let percent = Self.percent(from: line) { self.report("rendering… \(percent)", busy: true) }
            }
            let manager = FileManager.default
            guard manager.fileExists(atPath: partial.path) else {
                self.report("render failed — see ~/Library/Logs or run rendertitle by hand", busy: false)
                completion?(); return
            }
            try? manager.removeItem(at: movie)
            do { try manager.moveItem(at: partial, to: movie) } catch {
                self.report("could not publish the clip: \(error.localizedDescription)", busy: false)
                completion?(); return
            }
            self.report("installing into the Lock Screen slot…", busy: true)
            let install = Tools.run(installer, arguments: ["--install", movie.path])
            let ok = (install?.code ?? -1) == 0
            self.report(ok ? "Lock Screen clip installed (\(dayLength)s, matching the desktop)"
                           : "install failed: \(install?.out.suffix(160) ?? "unknown")", busy: false)
            completion?()
        }
    }

    private func report(_ text: String, busy: Bool) {
        DispatchQueue.main.async { self.status = text; self.busy = busy }
    }

    private static func percent(from line: String) -> String? {
        guard let range = line.range(of: "%") else { return nil }
        let head = line[..<range.lowerBound].suffix(6).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head + "%"
    }
}
