// ComposerModel.swift — the state behind the Composer window.
//
// The Composer does NOT reimplement the Starbound backdrop: it drives tools/starbound_mainmenu.py, the
// same generator the wallpaper uses. The preview and the export call it with the same arguments, so what
// you see in the window is what lands in the wallpaper folder — there is no second renderer to drift.

import Foundation
import SwiftUI

// MARK: - the generator's palette of choices (read from the tool, never duplicated here)

struct Palette: Decodable {
    struct Defaults: Decodable {
        let planet: String
        let masks: [Int]
        let maskAlpha: Double
        let dayLength: Double
        let cloudAlpha: Double
        let starsPerCell: Int
        let seed: Int
    }
    let planets: [String]
    let liquids: [String]
    let masks: [Int]
    let shadows: [Int]
    let moonScale: Double
    let planetScale: Double
    let defaults: Defaults
}

// MARK: - locating the tools

enum Tools {
    /// Bundled with this app (build.sh copies them in), so the Composer works even if the repo moves.
    static var resourcesDir: URL? { Bundle.main.resourceURL }

    static var script: URL? {
        let bundled = resourcesDir?.appendingPathComponent("tools/starbound_mainmenu.py")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let inRepo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/live-wallpaper/tools/starbound_mainmenu.py")
        return FileManager.default.fileExists(atPath: inRepo.path) ? inRepo : nil
    }

    static var compositor: URL? {
        let bundled = resourcesDir?.appendingPathComponent("tools/composite_pngs")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let inRepo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/live-wallpaper/build/composite_pngs")
        return FileManager.default.fileExists(atPath: inRepo.path) ? inRepo : nil
    }

    static let python = "/usr/bin/python3"

    /// Run the generator, returning stdout (nil on failure — the caller shows `lastError`).
    @discardableResult
    static func run(arguments: [String], timeout: TimeInterval = 300) -> (out: String, code: Int32)? {
        guard let script else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if let compositor { environment["LW_COMPOSITOR"] = compositor.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return ("timeout", -1) }
        let text = String(data: data, encoding: .utf8) ?? ""
        return (text, process.terminationStatus)
    }
}

// MARK: - the composer

final class Composer: ObservableObject {

    @Published var palette: Palette?
    @Published var toolsOK = true

    // planet / horizon
    @Published var planet = "garden"
    @Published var liquid = "none"
    @Published var masks: [Int] = [6, 11, 17]          // 0 = unused
    @Published var maskAlpha = 0.18
    @Published var hueShift = 0.0

    // sky
    @Published var cloudAlpha = 3.0
    @Published var starsPerCell = 80
    @Published var dayLength = 600.0                   // seconds per in-game day

    // the other bodies
    @Published var moons = 0
    @Published var moonTypes: [String] = ["moon", "barren", "tundra"]
    @Published var parentPlanet = "none"
    @Published var moonSize = 1.0
    @Published var planetSize = 1.0
    @Published var discShadow = 0                      // 0 = from the seed

    // identity / export
    @Published var seed = 1234567
    @Published var name = "starbound-custom"

    // state
    @Published var status = "ready"
    @Published var probe = ""
    @Published var busy = false
    @Published var previewURL: URL?
    @Published var previewToken = 0

    static let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.sikarek.starbound-composer", isDirectory: true)
    static let previewDir = cacheDir.appendingPathComponent("preview", isDirectory: true)

    init() {
        if Tools.script == nil || Tools.compositor == nil { toolsOK = false }
        palette = loadPalette()
        if let defaults = palette?.defaults {
            planet = defaults.planet
            masks = defaults.masks + [0, 0, 0]
            maskAlpha = defaults.maskAlpha
            dayLength = defaults.dayLength
            cloudAlpha = defaults.cloudAlpha
            starsPerCell = defaults.starsPerCell
            seed = defaults.seed
        }
    }

    private func loadPalette() -> Palette? {
        guard let result = Tools.run(arguments: ["--dump-options"]), result.code == 0,
              let data = result.out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Palette.self, from: data)
    }

    var scratchPlanet: String { palette?.planets.first ?? "garden" }
    var planetChoices: [String] { palette?.planets ?? [] }
    var liquidChoices: [String] { ["none"] + (palette?.liquids ?? []) }
    var worldChoices: [String] { ["none"] + (palette?.planets ?? []) }

    /// Every knob as the generator's command line. Both the preview and the export go through this.
    var generatorArguments: [String] {
        var args = ["--planet", planet, "--seed", String(seed)]
        args += ["--masks", masks.filter { $0 > 0 }.map(String.init).joined(separator: ",")]
        args += ["--mask-alpha", String(format: "%.3f", maskAlpha)]
        args += ["--liquid", liquid]
        args += ["--hue-shift", String(format: "%.1f", hueShift)]
        args += ["--cloud-alpha", String(format: "%.2f", cloudAlpha)]
        args += ["--day-length", String(format: "%.1f", dayLength)]
        args += ["--stars-per-cell", String(starsPerCell)]
        args += ["--moons", String(moons)]
        args += ["--moon-types", Array(moonTypes.prefix(moons)).joined(separator: ",")]
        args += ["--parent-planet", parentPlanet]
        args += ["--moon-size", String(format: "%.2f", moonSize)]
        args += ["--planet-size", String(format: "%.2f", planetSize)]
        args += ["--disc-shadow", String(discShadow)]
        return args
    }

    /// A signature of every knob the generator takes. The UI watches this: any change to it means the
    /// preview must be rebuilt. (Without this the window showed the first page forever — the controls
    /// wrote to the model and nothing ever re-ran the generator.)
    var signature: String {
        [planet, liquid, masks.map(String.init).joined(separator: ","), String(format: "%.3f", maskAlpha),
         String(format: "%.1f", hueShift), String(format: "%.2f", cloudAlpha), String(starsPerCell),
         String(format: "%.1f", dayLength), String(moons), Array(moonTypes.prefix(moons)).joined(separator: ","),
         parentPlanet, String(format: "%.2f", moonSize), String(format: "%.2f", planetSize),
         String(discShadow), String(seed)].joined(separator: "|")
    }

    private var pendingPreview: DispatchWorkItem?
    private var generation = 0

    /// Called on every knob change: coalesce a burst (a slider drag fires dozens of times) into one build.
    func schedulePreview(after delay: TimeInterval = 0.45) {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Writes the current combination into a FRESH folder and hands it to the preview. A new folder each
    /// time is what makes WebKit actually re-read the page and its images: same-URL file:// content is
    /// served from its cache, which is the other half of "the preview never changes".
    func refreshPreview() {
        guard toolsOK else { status = "tools not found — run build.sh to bundle them"; return }
        pendingPreview?.cancel()
        pendingPreview = nil
        generation += 1
        let token = generation
        let dir = Self.previewDir.appendingPathComponent("g\(token)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let args = generatorArguments + ["--out", dir.path]
        busy = true
        status = "building…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Tools.run(arguments: args)
            DispatchQueue.main.async {
                guard self.generation == token else { return }        // a newer build already won
                self.busy = false
                guard let result, result.code == 0 else {
                    self.status = "generator failed: " + (result?.out.split(separator: "\n").last.map(String.init) ?? "unknown error")
                    return
                }
                URLCache.shared.removeAllCachedResponses()
                self.previewURL = dir.appendingPathComponent("index.html")
                self.previewToken = token
                self.status = "preview updated"
                self.pruneOldPreviews(keep: token)
            }
        }
    }

    /// The old generations are dead weight (each carries its own copy of the art).
    private func pruneOldPreviews(keep: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Self.previewDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("g") {
            guard let number = Int(entry.lastPathComponent.dropFirst()) else { continue }
            if number < keep - 1 { try? fm.removeItem(at: entry) }
        }
    }

    func randomize() {
        guard let palette else { return }
        seed = Int.random(in: 1...9_999_999)
        planet = palette.planets.randomElement() ?? "garden"
        liquid = Bool.random() ? "none" : (palette.liquids.randomElement() ?? "none")
        let count = Int.random(in: 1...3)
        masks = (0..<3).map { $0 < count ? Int.random(in: 1...25) : 0 }
        hueShift = Double(Int.random(in: -180...180))
        moons = Int.random(in: 0...3)
        parentPlanet = Bool.random() ? "none" : (palette.planets.randomElement() ?? "none")
        moonTypes = (0..<3).map { _ in palette.planets.randomElement() ?? "moon" }
        moonSize = Double.random(in: 0.7...1.8)
        planetSize = Double.random(in: 0.7...1.6)
        discShadow = Int.random(in: 0...9)
        cloudAlpha = Double.random(in: 1.5...4.5)
        refreshPreview()
    }

    func resetToDefault() {
        planetsDefault()
        refreshPreview()
    }

    private func planetsDefault() {
        if let defaults = palette?.defaults {
            planet = defaults.planet
            masks = defaults.masks + [0, 0, 0]
            maskAlpha = defaults.maskAlpha
            dayLength = defaults.dayLength
            cloudAlpha = defaults.cloudAlpha
            starsPerCell = defaults.starsPerCell
        }
        liquid = "none"; hueShift = 0
        moons = 0; parentPlanet = "none"; moonSize = 1; planetSize = 1; discShadow = 0
    }

    // MARK: - export into the LiveWallpaper app

    static let libraryDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LiveWallpaper/wallpapers", isDirectory: true)

    var safeName: String {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? "starbound-custom" : cleaned
    }

    func export(useNow: Bool, completion: (() -> Void)? = nil) {
        guard toolsOK else { completion?(); return }
        busy = true
        status = "exporting…"
        let dir = Self.libraryDir.appendingPathComponent(safeName, isDirectory: true)
        let args = generatorArguments + ["--out", dir.path]
        let finalName = safeName
        DispatchQueue.global(qos: .userInitiated).async {
            // a fresh folder, so assets from a previous combination cannot linger (fewer moons, other masks)
            try? FileManager.default.removeItem(at: dir)
            let result = Tools.run(arguments: args)
            DispatchQueue.main.async {
                self.busy = false
                guard let result, result.code == 0 else {
                    self.status = "export failed: " + (result?.out.split(separator: "\n").last.map(String.init) ?? "unknown error")
                    completion?()
                    return
                }
                self.status = "exported “\(finalName)” to the wallpaper library"
                self.tellLiveWallpaper(useNow: useNow, name: finalName)
                completion?()
            }
        }
    }

    /// The LiveWallpaper app listens for these: one refreshes its library, one also puts this wallpaper
    /// on every display. Writing its preference domain is the same thing its own menu does.
    private func tellLiveWallpaper(useNow: Bool, name: String) {
        if useNow, let defaults = UserDefaults(suiteName: "com.sikarek.livewallpaper") {
            defaults.set(name, forKey: "selected")
            defaults.synchronize()
        }
        let center = DistributedNotificationCenter.default()
        center.post(name: NSNotification.Name("com.sikarek.livewallpaper.refresh"), object: nil)
        if useNow {
            center.post(name: NSNotification.Name("com.sikarek.livewallpaper.apply"), object: nil)
        }
    }
}
