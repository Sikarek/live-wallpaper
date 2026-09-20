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
    let skyTypes: [String]?
    let liquids: [String]
    let masks: [Int]
    let maskPerPlanet: [String: [Int]]?
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

    /// rendertitle makes the Lock Screen clip from the same plan; it is bundled for the same reason.
    static var renderTitle: URL? {
        let bundled = resourcesDir?.appendingPathComponent("tools/rendertitle")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let inRepo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/live-wallpaper/build/rendertitle")
        return FileManager.default.fileExists(atPath: inRepo.path) ? inRepo : nil
    }

    static var lockscreenTool: URL? {
        let bundled = resourcesDir?.appendingPathComponent("tools/lockscreen.py")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let inRepo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/live-wallpaper/tools/lockscreen.py")
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

    /// Run a long tool and hand each output line to `onLine` as it arrives (renders report progress).
    static func runStreaming(executable: URL, arguments: [String], onLine: @escaping (String) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if let compositor { environment["LW_COMPOSITOR"] = compositor.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return }
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
        }
        process.waitUntilExit()
    }

    /// Run one of the bundled tools and return its output. `run(arguments:)` runs the generator; this
    /// takes the script explicitly — without it, calling any *other* tool silently ran the generator
    /// with that path as an argument and the caller parsed argparse's usage text.
    @discardableResult
    static func run(_ script: URL, arguments: [String], timeout: TimeInterval = 300) -> (out: String, code: Int32)? {
        runProcess(script, arguments: arguments, timeout: timeout)
    }

    /// Run the generator, returning stdout (nil on failure — the caller shows `lastError`).
    @discardableResult
    static func run(arguments: [String], timeout: TimeInterval = 300) -> (out: String, code: Int32)? {
        guard let script else { return nil }
        return runProcess(script, arguments: arguments, timeout: timeout)
    }

    private static func runProcess(_ script: URL, arguments: [String],
                                   timeout: TimeInterval) -> (out: String, code: Int32)? {
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

    /// A one-line summary a person can read: what is in the slot and whether it matches.
    static func slotStatusLine(_ raw: String) -> String {
        let lines = raw.split(separator: "\n").map(String.init)
        let duration = lines.first { $0.contains("duration") }.flatMap { line -> String? in
            let parts = line.split(separator: " ")
            guard let index = parts.firstIndex(where: { $0 == "duration" }), index + 1 < parts.count else { return nil }
            return String(parts[index + 1])
        } ?? "?"
        let verdict = lines.first { $0.contains("MATCHED") || $0.contains("MISMATCH") } ?? ""
        return "slot video \(duration)s \u{2022} " + verdict.trimmingCharacters(in: .whitespaces)
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
    @Published var savedWallpaper = ""
    @Published var savedList: [String] = []
    @Published var slotStatus = "reading the Lock Screen slot…"
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
    /// the planet you orbit can be a gas giant, which is why this list is not just the biomes
    var worldChoices: [String] { ["none"] + (palette?.skyTypes ?? palette?.planets ?? []) }

    /// Every knob as the generator's command line. Both the preview and the export go through this.
    var generatorArguments: [String] {
        var args = ["--planet", planet, "--seed", String(seed)]
        args += ["--masks", masks.filter { $0 > 0 }.map(String.init).joined(separator: ",")]
        args += ["--mask-alpha", String(format: "%.3f", maskAlpha)]
        args += ["--liquid", liquid]
        args += ["--hue-shift", String(format: "%.1f", hueShift)]
        args += ["--cloud-alpha", String(format: "%.2f", cloudAlpha)]
        args += ["--day-length", String(Int(dayLength.rounded()))]   // whole seconds: the video must match
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
    func refreshSavedList() {
        savedList = Self.savedWallpapers()
        if !savedList.contains(savedWallpaper) { savedWallpaper = savedList.first ?? "" }
    }

    func refreshSlotStatus() {
        DispatchQueue.global(qos: .utility).async {
            let text = self.lockScreenStatus()
            DispatchQueue.main.async { self.slotStatus = text }
        }
    }

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

    /// Randomise the three mask numbers. The count follows the biome's own maskPerPlanetRange
    /// (garden 3, scorchedcity 2-3, ocean 1-2, ...) — the rule the engine uses to decide how many
    /// surface masks a world gets — and the numbers are distinct, as the engine draws them per planet.
    func randomMasks() {
        let rule = palette?.maskPerPlanet?[planet] ?? [1, 3]
        let low = rule.first ?? 1, high = rule.count > 1 ? rule[1] : low
        let count = Int.random(in: low...max(low, high))
        let pool = palette?.masks ?? Array(1...25)
        var picked: [Int] = []
        var guardCount = 0
        while picked.count < count && guardCount < 200 {
            guardCount += 1
            if let candidate = pool.randomElement(), !picked.contains(candidate) { picked.append(candidate) }
        }
        masks = picked + Array(repeating: 0, count: max(0, 3 - picked.count))
        schedulePreview()
    }

    func randomize() {
        guard let palette else { return }
        seed = Int.random(in: 1...9_999_999)
        planet = palette.planets.randomElement() ?? "garden"
        liquid = Bool.random() ? "none" : (palette.liquids.randomElement() ?? "none")
        let rule = palette.maskPerPlanet?[planet] ?? [1, 3]
        let low = rule.first ?? 1, high = rule.count > 1 ? rule[1] : low
        let count = Int.random(in: low...max(low, high))
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

    // MARK: - branch off a wallpaper that already exists

    /// backdrop.json has been written by two versions of the generator; one of them stored mask numbers
    /// as strings. Decode either, or a wallpaper you already have would refuse to load.
    enum FlexibleInt: Decodable {
        case value(Int)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) { self = .value(number); return }
            if let number = try? container.decode(Double.self) { self = .value(Int(number)); return }
            if let text = try? container.decode(String.self), let number = Int(text) {
                self = .value(number); return
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected a mask number")
        }
    }

    struct SavedPlan: Decodable {
        struct Orbiter: Decodable { let type: String; let parent: Bool? }
        let planet: String
        let masks: [FlexibleInt]?
        let maskAlpha: Double?
        let liquid: String?
        let hueShift: Double?
        let cloudAlpha: Double?
        let starsPerCell: Int?
        let dayLength: Double?
        let seed: Int?
        let moonSize: Double?
        let planetSize: Double?
        let discShadow: Int?
        let orbiters: [Orbiter]?
    }

    /// Wallpapers in the library that carry a plan, newest name first — these are the ones this app
    /// (or the CLI) produced, so every knob can be restored exactly.
    static func savedWallpapers() -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { manager.fileExists(atPath: $0.appendingPathComponent("backdrop.json").path) }
            .map { $0.lastPathComponent }.sorted()
    }

    /// Adopt a saved combination so a new idea can start from one that already worked.
    func load(from folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("backdrop.json")),
              let plan = try? JSONDecoder().decode(SavedPlan.self, from: data) else {
            status = "that wallpaper has no backdrop.json to load"
            return
        }
        name = folder.lastPathComponent
        savedWallpaper = folder.lastPathComponent
        planet = plan.planet
        liquid = plan.liquid ?? "none"
        let restoredMasks = (plan.masks ?? []).map { if case .value(let number) = $0 { return number } else { return 0 } }
        masks = restoredMasks + Array(repeating: 0, count: max(0, 3 - restoredMasks.count))
        if let value = plan.maskAlpha { maskAlpha = value }
        if let value = plan.hueShift { hueShift = value }
        if let value = plan.cloudAlpha { cloudAlpha = value }
        if let value = plan.starsPerCell { starsPerCell = value }
        if let value = plan.dayLength { dayLength = value.rounded() }
        if let value = plan.seed { seed = value }
        if let value = plan.moonSize { moonSize = value }
        if let value = plan.planetSize { planetSize = value }
        if let value = plan.discShadow { discShadow = value }
        let bodies = plan.orbiters ?? []
        let moons = bodies.filter { ($0.parent ?? false) == false }
        self.moons = min(3, moons.count)
        moonTypes = (0..<3).map { index in index < moons.count ? moons[index].type : "moon" }
        parentPlanet = bodies.first { ($0.parent ?? false) == true }?.type ?? "none"
        status = "loaded \u{201C}\(folder.lastPathComponent)\u{201D} — change what you like and export a copy"
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
