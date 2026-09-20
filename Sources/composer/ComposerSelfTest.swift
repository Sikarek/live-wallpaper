// ComposerSelfTest.swift — proofs, not vibes.
//
//   ./build/StarboundComposer.app/Contents/MacOS/StarboundComposer --self-test
//
// For each combination it generates the wallpaper, loads the real page in a real WebKit view and asks
// the page what it drew; then it checks the moons actually move, that the hue shift changes pixels, and
// that an exported folder contains everything the wallpaper app needs.

import AppKit
import WebKit

/// Knob changes must rebuild the preview. This drives the same model API the window's `onChange` calls
/// and requires the rendered page to differ — the bug it guards against is "the controls update the
/// model and nothing re-renders", which looks exactly like controls that do nothing.
func previewUpdateChecks(then done: @escaping () -> Void) {
    print("== 5. changing a knob rebuilds the preview ==")
    let composer = Composer()
    check(composer.palette != nil, "the Composer read its palette from the tool")
    composer.name = "selftest-preview"

    func waitForPreview(from token: Int, attempts: Int = 0, then: @escaping () -> Void) {
        if composer.previewToken != token {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { then() }
            return
        }
        if attempts > 600 {
            check(false, "the preview rebuild finished (token \(token), status \(composer.status))")
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForPreview(from: token, attempts: attempts + 1, then: then)
        }
    }

    func snapshotOfPreview(_ label: String, then: @escaping (Int, String?, URL?) -> Void) {
        guard let page = composer.previewURL else {
            check(false, "[\(label)] produced a page (\(composer.status))")
            done()
            return
        }
        snapshot(page, query: "t=0") { image in
            then(luminanceSpread(image), pixelHash(image).description, page)
        }
    }

    // combination A: garden, no moons
    composer.planet = "garden"; composer.liquid = "none"; composer.moons = 0
    composer.parentPlanet = "none"; composer.seed = 1
    let tokenA = composer.previewToken
    composer.refreshPreview()
    waitForPreview(from: tokenA) {
        snapshotOfPreview("garden") { spreadA, hashA, pageA in
            // combination B: midnight + water + three moons + an ocean parent planet
            composer.planet = "midnight"; composer.liquid = "water"; composer.moons = 3
            composer.moonTypes = ["moon", "barren", "tundra"]; composer.parentPlanet = "ocean"; composer.seed = 42
            let tokenB = composer.previewToken
            composer.refreshPreview()
            waitForPreview(from: tokenB) {
                snapshotOfPreview("midnight") { spreadB, hashB, pageB in
                    check(spreadA > 20 && spreadB > 20, "both previews rendered real pixels (\(spreadA) / \(spreadB))")
                    check(pageB?.path != pageA?.path,
                          "each build gets its own folder, so WebKit cannot serve a cached page or image")
                    check(hashA != hashB, "the preview actually changed with the options")
                    probePage(pageB ?? URL(fileURLWithPath: "/"), query: "t=0") { json, error in
                        check(json != nil, "the second combination's page renders cleanly (\(error))")
                        check((json?["orbitersDrawn"] as? Int) == 4,
                              "it draws the three moons and the parent planet (got \(json?["orbitersDrawn"] ?? "?") )")
                        check((json?["horizonWidth"] as? Int) == 1764, "the horizon band is there")
                        // a burst of changes (a slider drag) must coalesce into ONE rebuild
                        let before = composer.previewToken
                        for _ in 0..<6 { composer.schedulePreview(after: 0.3) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            check(composer.previewToken == before + 1,
                                  "six quick changes coalesced into one rebuild (\(before) -> \(composer.previewToken))")
                            done()
                        }
                    }
                }
            }
        }
    }
}

private var failures: [String] = []
private var checks = 0

/// Probe views must stay alive until their load callbacks fire. Keeping them in an array is explicit
/// (an associated-object key on NSApp both warns and leaks every view it pins).
private var liveProbes: [ProbeWebView] = []

private func keepAlive(_ view: ProbeWebView) {
    liveProbes.append(view)
    if liveProbes.count > 24 { liveProbes.removeFirst(liveProbes.count - 24) }
}

private func check(_ ok: Bool, _ label: String) {
    checks += 1
    print(ok ? "  ok    \(label)" : "  FAIL  \(label)")
    if !ok { failures.append(label) }
}

private func probePage(_ page: URL, query: String?, completion: @escaping ([String: Any]?, String) -> Void) {
    let view = ProbeWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                            configuration: WKWebViewConfiguration())
    view.query = query
    view.onProbe = { text in
        if text.hasPrefix("LWERROR") || text.hasPrefix("ERROR") { completion(nil, text); return }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(nil, "probe returned nothing usable: " + text.prefix(120)); return
        }
        completion(json, "")
    }
    view.load(page: page)
    keepAlive(view)
}

private func snapshot(_ page: URL, query: String?, completion: @escaping (NSBitmapImageRep?) -> Void) {
    let view = ProbeWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                            configuration: WKWebViewConfiguration())
    view.query = query
    view.onProbe = { _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: 640, height: 360)
            view.takeSnapshot(with: config) { image, _ in
                completion(image.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation ?? Data()) })
            }
        }
    }
    view.load(page: page)
    keepAlive(view)
}

/// min/max luminance over a coarse grid — enough to tell "the sky rendered" from "a black rectangle"
private func luminanceSpread(_ rep: NSBitmapImageRep?) -> Int {
    guard let rep else { return -1 }
    var lo = 255, hi = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 24)) {
        for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 32)) {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            let lum = Int(((colour.redComponent + colour.greenComponent + colour.blueComponent) / 3) * 255)
            lo = min(lo, lum); hi = max(hi, lum)
        }
    }
    return hi - lo
}

private func pixelHash(_ rep: NSBitmapImageRep?) -> Int {
    guard let rep, let data = rep.representation(using: .png, properties: [:]) else { return 0 }
    return data.hashValue
}

/// A liquid world is the liquid as its base **plus the biome image clipped to the surface masks**, so the
/// masks must visibly change it (land in the sea). The bug this guards against: replacing the base with
/// the liquid and never drawing the biome, which turns every planet into a flat ocean.
func liquidChecks(then done: @escaping () -> Void) {
    print("== 6. a surface liquid keeps its landmasses ==")
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("composer-liquid-\(getpid())")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    func generate(_ name: String, extra: [String], then next: @escaping (URL) -> Void) {
        let folder = work.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: folder)
        let result = Tools.run(arguments: ["--planet", "garden", "--liquid", "water", "--masks", "6,11,17",
                                          "--seed", "1234567", "--out", folder.path] + extra)
        let ok = (result?.code ?? -1) == 0
        check(ok, "[\(name)] liquid world generated")
        if !ok { print("      " + (result?.out.suffix(200) ?? "")); done(); return }
        next(folder)
    }

    func horizon(_ folder: URL) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent("assets/horizon.png"))
    }

    /// Ask the compositor itself how much of a plate is opaque — the coverage number is what makes the
    /// "do the masks stack?" question answerable instead of guessable.
    func coverage(_ image: URL) -> Double? {
        guard let compositor = Tools.compositor else { return nil }
        let process = Process()
        process.executableURL = compositor
        process.arguments = [work.appendingPathComponent("probe.png").path, "1764", "202",
                             "--over", image.path, "--stats"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let range = text.range(of: "stats: ") else { return nil }
        let number = text[range.upperBound...].prefix(6)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(number)
    }

    // one mask vs three: the masks STACK, so a wider mask set must cover more land. Before the fix the
    // files were passed to a single pass and butted side by side, so only the middle pair reached the
    // canvas and every "3 masks" wallpaper was really a 1-mask wallpaper.
    generate("one-mask", extra: ["--masks", "6"]) { one in
        generate("three-masks", extra: ["--masks", "6,11,17"]) { three in
            let single = horizon(one), stacked = horizon(three)
            check(single != nil && stacked != nil, "both liquid worlds produced a horizon image")
            check(single != stacked, "a different mask set changes the land in the sea")
            check(FileManager.default.fileExists(atPath: three.appendingPathComponent("assets/landmass.png").path),
                  "the landmass plate was composited")

            let oneCoverage = coverage(one.appendingPathComponent("assets/landmass.png"))
            let threeCoverage = coverage(three.appendingPathComponent("assets/landmass.png"))
            check(oneCoverage != nil && threeCoverage != nil, "the compositor reports coverage")
            if let oneCoverage, let threeCoverage {
                print(String(format: "      landmass coverage: 1 mask %.1f%%, 3 masks %.1f%%", oneCoverage, threeCoverage))
                check(threeCoverage > oneCoverage + 5,
                      "three masks cover more land than one — the masks stack instead of sitting side by side")
            }
            // and a dry world must still render (the dry path uses the same stacking now)
            let dry = work.appendingPathComponent("dry")
            let result = Tools.run(arguments: ["--planet", "garden", "--masks", "6,11,17", "--seed", "1234567",
                                               "--out", dry.path])
            check((result?.code ?? -1) == 0, "a dry world still generates")
            check(coverage(dry.appendingPathComponent("assets/horizon.png")) ?? 0 > 20, "the dry horizon has content")
            done()
        }
    }
}

struct SelfTestCase {
    let name: String
    let arguments: [String]
    let expectedOrbiters: Int
    let everyOrbiterNamed: [String: Int]     // biome -> how many bodies of that kind
}

struct BackdropPlan: Decodable {
    struct Engine: Decodable {
        let satelliteArea: [Double]
        let imageScale: [String: Double]
    }
    struct Orbiter: Decodable {
        let x: Double
        let y: Double
        let type: String
        let scale: Double
    }
    let dayLength: Double
    let engine: Engine
    let orbiters: [Orbiter]
}

/// The engine's own placement maths, implemented a second time in Swift: if this and the page agree,
/// the discs really are where backOrbiters() says they should be.
func expectedOrbiters(_ plan: BackdropPlan, seconds: Double, viewW: Double, viewH: Double,
                      interfaceScale: Double = 1.0, discSize: Double = 542)
    -> [(type: String, x: Int, y: Int, size: Int)] {
    let pixelRatio = 0.125 + ((viewH / 1080.0) * 3.0 - 0.125) * interfaceScale
    // the page works in VIEW units (screen px / pixelRatio) and only scales to pixels when drawing
    let viewUnitsW = viewW / pixelRatio
    let cx = viewUnitsW / 2, cy = 0.0
    let theta = 2 * Double.pi * seconds / plan.dayLength
    var out: [(String, Int, Int, Int)] = []
    for body in plan.orbiters {
        let dx = body.x * plan.engine.satelliteArea[0] - cx
        let dy = body.y * plan.engine.satelliteArea[1] - cy
        let x = cx + dx * cos(theta) - dy * sin(theta)
        let y = cy + dx * sin(theta) + dy * cos(theta)
        let px = x * pixelRatio, py = y * pixelRatio
        let size = discSize * (plan.engine.imageScale[body.type] ?? plan.engine.imageScale["default"] ?? 0.1125)
            * body.scale * pixelRatio
        let visible = !(px + size / 2 < 0 || px - size / 2 > viewW || py + size / 2 < 0 || py - size / 2 > viewH)
        if visible { out.append((body.type, Int(px.rounded()), Int(py.rounded()), Int(size.rounded()))) }
    }
    return out
}

func runComposerSelfTest() {
    let cases = [
        SelfTestCase(name: "garden, no moons",
                     arguments: ["--planet", "garden", "--masks", "6,11,17", "--seed", "1234567"],
                     expectedOrbiters: 0, everyOrbiterNamed: [:]),
        SelfTestCase(name: "midnight + water + 3 moons + ocean parent",
                     arguments: ["--planet", "midnight", "--liquid", "water", "--moons", "3",
                                 "--moon-types", "moon,barren,tundra", "--parent-planet", "ocean",
                                 "--seed", "42"],
                     expectedOrbiters: 4, everyOrbiterNamed: ["ocean": 1, "moon": 1, "barren": 1, "tundra": 1]),
        SelfTestCase(name: "volcanic + 1 moon + shadow 7 + hue shift",
                     arguments: ["--planet", "volcanic", "--moons", "1", "--moon-types", "moon",
                                 "--disc-shadow", "7", "--hue-shift", "60", "--seed", "5"],
                     expectedOrbiters: 1, everyOrbiterNamed: ["moon": 1]),
    ]

    print("== 1. the generator's palette of choices ==")
    var palette: Palette?
    if let result = Tools.run(arguments: ["--dump-options"]), result.code == 0,
       let data = result.out.data(using: .utf8) {
        palette = try? JSONDecoder().decode(Palette.self, from: data)
    }
    check(palette != nil, "generator answers --dump-options with JSON")
    check(palette?.planets.count == 17, "17 biomes with disc art (got \(palette?.planets.count ?? -1))")
    check(palette?.liquids.count == 6, "6 surface liquids")
    check(palette?.masks.count == 25, "25 surface masks")
    check(palette?.shadows.count == 9, "9 disc shadows")
    check((palette?.moonScale ?? 0) == 1.5 && (palette?.planetScale ?? 0) == 3.0,
          "engine scales: moons 1.5x, parent planet 3.0x")
    check(Tools.compositor != nil, "the CoreGraphics compositor is bundled")

    print("== 2. generate, render, and interrogate each combination ==")
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("composer-selftest-\(getpid())")
    try? FileManager.default.removeItem(at: work)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    var index = 0
    var exportedFolder: URL?

    func nextCase() {
        guard index < cases.count else { return runExportChecks(work: work, folder: exportedFolder) }
        let test = cases[index]
        index += 1
        let folder = work.appendingPathComponent("case\(index)")
        if index == 2 { exportedFolder = folder }          // case 2 doubles as the export check
        let result = Tools.run(arguments: test.arguments + ["--out", folder.path])
        let ok = (result?.code ?? -1) == 0
        check(ok, "[\(test.name)] generator exits 0")
        if !ok { print("      " + (result?.out.suffix(300) ?? "")); nextCase(); return }

        let page = folder.appendingPathComponent("index.html")
        check(FileManager.default.fileExists(atPath: page.path), "[\(test.name)] wrote index.html")

        var positionsAtZero: [String: Int] = [:]
        var cloudsSeenSomewhere = false
        let moments = ["t=0", "t=150", "t=300", "t=450"]
        var momentIndex = 0

        // the wallpaper documents how it was made; the harness replays the engine's maths from that plan
        var plan: BackdropPlan?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("backdrop.json")) {
            plan = try? JSONDecoder().decode(BackdropPlan.self, from: data)
        }
        check(plan != nil, "[\(test.name)] wrote backdrop.json describing the combination")
        if let plan { check(plan.orbiters.count == test.expectedOrbiters,
                            "[\(test.name)] plan lists \(test.expectedOrbiters) sky bodies") }

        func seconds(of query: String) -> Double {
            Double(query.replacingOccurrences(of: "t=", with: "")) ?? 0
        }

        func sampleMoment() {
            guard momentIndex < moments.count else {
                check(cloudsSeenSomewhere,
                      "[\(test.name)] clouds show up in the sky at some point of the day")
                nextCase()
                return
            }
            let query = moments[momentIndex]
            momentIndex += 1
            probePage(page, query: query) { json, error in
                check(json != nil, "[\(test.name)] \(query): page renders without a JS error (\(error))")
                guard let json else { sampleMoment(); return }
                let stars = json["starsDrawn"] as? Int ?? 0
                let clouds = json["cloudsDrawn"] as? Int ?? 0
                let orbiters = json["orbitersDrawn"] as? Int ?? -1
                let horizon = json["horizonWidth"] as? Int ?? 0
                let bodies = json["orbiters"] as? [[String: Any]] ?? []
                let viewW = (json["w"] as? NSNumber)?.doubleValue ?? 1280
                let viewH = (json["h"] as? NSNumber)?.doubleValue ?? 720
                print("      \(query): stars=\(stars) clouds=\(clouds) bodies=\(orbiters) horizon=\(horizon)")
                if clouds > 0 { cloudsSeenSomewhere = true }
                check(stars > 200, "[\(test.name)] \(query): drew a starfield (\(stars) stars)")
                check(horizon > 1000, "[\(test.name)] \(query): drew the planet horizon (\(horizon)px)")

                if let plan {
                    // independent implementation of backOrbiters(): same place, same size, same culling
                    let expected = expectedOrbiters(plan, seconds: seconds(of: query), viewW: viewW, viewH: viewH)
                    let got = bodies.compactMap { body -> (String, Int, Int, Int)? in
                        guard let type = body["type"] as? String, let x = body["x"] as? Int,
                              let y = body["y"] as? Int, let size = body["size"] as? Int else { return nil }
                        return (type, x, y, size)
                    }
                    check(got.count == expected.count,
                          "[\(test.name)] \(query): engine maths says \(expected.count) bodies on screen, page drew \(got.count)")
                    var mismatched: [String] = []
                    for e in expected where !got.contains(where: { $0.1 == e.x && $0.2 == e.y && abs($0.3 - e.size) <= 2 }) {
                        mismatched.append("\(e.type)@\(e.x),\(e.y) \(e.size)px")
                    }
                    check(mismatched.isEmpty,
                          "[\(test.name)] \(query): every body sits exactly where the engine places it"
                          + (mismatched.isEmpty ? "" : " — missing \(mismatched.joined(separator: ", "))"))
                    if query == "t=0" && test.expectedOrbiters > 0 {
                        check(expected.count >= 1, "[\(test.name)] at least one body is on screen at t=0")
                    }
                }

                if query == "t=0" {
                    for body in bodies {
                        positionsAtZero["\(body["type"] ?? "?")@\(body["x"] ?? -1)"] = (body["y"] as? Int) ?? -1
                    }
                }
                if query == "t=300" {
                    // half a day later the sky has turned: the wheels turn together, so check the rotation
                    check((json["starRotation"] as? NSNumber)?.doubleValue ?? 0 != 0,
                          "[\(test.name)] the star wheel advanced by t=300")
                }
                sampleMoment()
            }
        }
        sampleMoment()
    }

    func runExportChecks(work: URL, folder: URL?) {
        print("== 3. the exported folder is complete ==")
        if let folder {
            let fm = FileManager.default
            check(fm.fileExists(atPath: folder.appendingPathComponent("index.html").path), "index.html present")
            check(fm.fileExists(atPath: folder.appendingPathComponent("assets/horizon.png").path), "horizon.png present")
            check(fm.fileExists(atPath: folder.appendingPathComponent("assets/disc0.png").path), "disc art present")
            let assets = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("assets").path)) ?? []
            check(assets.contains { $0.hasPrefix("stars") }, "star sheets present")
            check(assets.filter { $0.hasSuffix(".png") }.count > 15, "assets folder populated (\(assets.count) entries)")
        } else {
            check(false, "an exported folder to inspect")
        }

        print("== 4. the hue shift really changes pixels ==")
        let page = (folder ?? work).appendingPathComponent("index.html")
        snapshot(page, query: "t=60") { a in
            let spread = luminanceSpread(a)
            check(spread > 20, "the rendered page is not a flat rectangle (luminance spread \(spread))")
            let h1 = pixelHash(a)
            let hueFolder = work.appendingPathComponent("hue")
            let result = Tools.run(arguments: ["--planet", "volcanic", "--moons", "1", "--hue-shift", "150",
                                               "--seed", "5", "--out", hueFolder.path])
            check((result?.code ?? -1) == 0, "generated a hue-shifted variant")
            snapshot(hueFolder.appendingPathComponent("index.html"), query: "t=60") { b in
                check(pixelHash(b) != h1, "a 150° hue shift produces different pixels")
                previewUpdateChecks { liquidChecks { finish() } }
            }
        }
    }

    func finish() {
        print("")
        if failures.isEmpty {
            print("SELF-TEST PASSED — \(checks) checks")
            exit(0)
        }
        print("SELF-TEST FAILED — \(failures.count) of \(checks) checks failed:")
        for f in failures { print("  - \(f)") }
        exit(1)
    }

    // nothing may happen on a WKWebView without a live run loop: hop once so the app is up
    DispatchQueue.main.async { nextCase() }
}

final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        runComposerSelfTest()
    }
}

/// `--dump-a11y` — build the real window, let the first preview land, then print every control the
/// accessibility API can see. Self-inspection needs no TCC permission (screencapture does, and is
/// blocked here), and it proves the layout is populated rather than collapsed.
final class DumpA11yDelegate: NSObject, NSApplicationDelegate {
    private let appDelegate = ComposerAppDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = appDelegate.buildWindow()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            print("window: \"\(window.title)\" \(Int(window.frame.width))x\(Int(window.frame.height)) "
                  + "content \(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))")
            let application = AXUIElementCreateApplication(getpid())
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], !windows.isEmpty else {
                print("FAIL: no windows in the accessibility tree"); exit(1)
            }
            var counts: [String: Int] = [:]
            for (index, windowElement) in windows.enumerated() {
                print("  window \(index + 1):")
                self.dump(windowElement, depth: 4, counts: &counts)
            }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("  controls: \(summary)")
            let buttons = counts["AXButton"] ?? 0, sliders = counts["AXSlider"] ?? 0
            let pickers = counts["AXPopUpButton"] ?? 0, fields = counts["AXTextField"] ?? 0
            let ok = buttons >= 4 && sliders >= 5 && pickers >= 6 && fields >= 2
            print(ok ? "DUMP OK — every control group is present" : "DUMP INCOMPLETE — some controls are missing")

            // And now the part the user actually cares about: does changing something in THIS window
            // rebuild the preview? The knobs are set on the model (exactly what a click does), so the
            // view's onChange has to fire for the page to change.
            let composer = self.appDelegate.composer
            print("  before: \(composer.status) — page \(composer.previewURL?.deletingLastPathComponent().lastPathComponent ?? "none")")
            composer.planet = "midnight"
            composer.liquid = "water"
            composer.moons = 3
            composer.moonTypes = ["moon", "barren", "tundra"]
            composer.parentPlanet = "ocean"
            DispatchQueue.main.asyncAfter(deadline: .now() + 26) {
                print("  after:  \(composer.status) — page \(composer.previewURL?.deletingLastPathComponent().lastPathComponent ?? "none")")
                print("  probe:  \(composer.probe.isEmpty ? "<none>" : composer.probe)")
                // Assert on the folder's own plan, not on how many bodies happen to be on screen at this
                // instant: the sky keeps turning, so a live moment legitimately shows a subset.
                let plan = composer.previewURL?.deletingLastPathComponent().appendingPathComponent("backdrop.json")
                var bodies = -1, planet = "?"
                if let plan, let data = try? Data(contentsOf: plan),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    bodies = (json["orbiters"] as? [[String: Any]])?.count ?? -1
                    planet = json["planet"] as? String ?? "?"
                }
                let followed = bodies == 4 && planet == "midnight"
                print("  plan:   planet=\(planet) bodies=\(bodies) (expected midnight / 4)")
                print(followed && ok ? "INTERACTIVE OK — the window's preview followed the knob change"
                                     : "INTERACTIVE FAILED — the preview did not follow the change")
                exit(followed && ok ? 0 : 1)
            }
        }
    }

    private func dump(_ element: AXUIElement, depth: Int, counts: inout [String: Int]) {
        guard depth > 0 else { return }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            var role: CFTypeRef?, title: CFTypeRef?, desc: CFTypeRef?, val: CFTypeRef?
            var pos: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size)
            var point = CGPoint.zero, extent = CGSize.zero
            if let pos, CFGetTypeID(pos) == AXValueGetTypeID() { AXValueGetValue(pos as! AXValue, .cgPoint, &point) }
            if let size, CFGetTypeID(size) == AXValueGetTypeID() { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
            let roleName = role as? String ?? "?"
            counts[roleName, default: 0] += 1
            let label = ([title as? String, desc as? String] + [val.map { String(describing: $0) }])
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let indent = String(repeating: "    ", count: 5 - depth)
            print("\(indent)\(roleName.replacingOccurrences(of: "AX", with: "")) \(label.prefix(38))"
                  + "  [\(Int(point.x)),\(Int(point.y)) \(Int(extent.width))x\(Int(extent.height))]")
            dump(child, depth: depth - 1, counts: &counts)
        }
    }
}

/// `--export <name> [--planet x] [--moons n] [--parent-planet y] [--seed n] [--use-now] [--library DIR]`
/// — runs the very same export the window's button runs (headless), so the export path itself is
/// testable and scriptable, not just the pieces around it.
final class ExportDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    init(arguments: [String]) { self.arguments = arguments }

    private func value(of flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let composer = Composer()
        composer.name = value(of: "--export") ?? "starbound-custom"
        if let planet = value(of: "--planet") { composer.planet = planet }
        if let liquid = value(of: "--liquid") { composer.liquid = liquid }
        if let moons = value(of: "--moons"), let count = Int(moons) { composer.moons = count }
        if let parent = value(of: "--parent-planet") { composer.parentPlanet = parent }
        if let seed = value(of: "--seed"), let number = Int(seed) { composer.seed = number }
        print("exporting \"\(composer.safeName)\" with: planet=\(composer.planet) liquid=\(composer.liquid) "
              + "moons=\(composer.moons) parent=\(composer.parentPlanet) seed=\(composer.seed)")
        composer.export(useNow: arguments.contains("--use-now")) {
            let folder = Composer.libraryDir.appendingPathComponent(composer.safeName)
            let fm = FileManager.default
            let index = fm.fileExists(atPath: folder.appendingPathComponent("index.html").path)
            let plan = fm.fileExists(atPath: folder.appendingPathComponent("backdrop.json").path)
            let discs = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("assets").path))?
                .filter { $0.hasPrefix("disc") && $0.hasSuffix(".png") }.count ?? 0
            print("  status: \(composer.status)")
            print("  wrote:  \(folder.path)")
            print("  index.html=\(index) backdrop.json=\(plan) discArt=\(discs) (expected \(composer.moons + (composer.parentPlanet == "none" ? 0 : 1)))")
            exit(index && plan ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("export timed out"); exit(3) }
    }
}

/// `--probe <folder> [--query t=300] [--size WxH]` — loads a page and prints the raw report, plus the
/// state of every sprite the page tried to load. This is the "show me why it is empty" tool.
final class RawProbeDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    init(arguments: [String]) { self.arguments = arguments }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var folder: URL?
        var query: String?
        var size = NSSize(width: 1280, height: 720)
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--probe":  index += 1; if index < arguments.count { folder = URL(fileURLWithPath: arguments[index]) }
            case "--query":  index += 1; if index < arguments.count { query = arguments[index] }
            case "--size":
                index += 1
                if index < arguments.count {
                    let parts = arguments[index].split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
                }
            default: break
            }
            index += 1
        }
        guard let folder else { print("usage: --probe <wallpaper folder> [--query t=300] [--size WxH]"); exit(2) }
        let page = folder.hasDirectoryPath ? folder.appendingPathComponent("index.html") : folder

        let view = ProbeWebView(frame: NSRect(origin: .zero, size: size),
                                configuration: WKWebViewConfiguration())
        view.query = query
        view.onProbe = { text in
            if text.hasPrefix("LWERROR") || text.hasPrefix("ERROR") {
                print("PAGE ERROR: \(text)"); exit(1)
            }
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("raw probe: \(text)"); exit(0)
            }
            print("== page report ==")
            for key in ["w", "h", "starsDrawn", "clouds", "cloudsDrawn", "orbitersDrawn", "horizonWidth",
                        "starRotation", "pixelRatio", "planetRatio", "frames", "fps"] {
                print("  \(key): \(json[key] ?? "—")")
            }
            print("  cloudState: \(json["cloudState"] ?? "—")")
            print("  starWidths: \(json["starWidths"] ?? "—")")
            print("  orbiters: \(json["orbiters"] ?? "—")")

            // and now the real question: did the sprite files resolve for the web view at all?
            let script = """
            (function () {
              var out = [];
              var names = [horizonImage].concat(orbiterImages).concat(cloudImages);
              var labels = ['horizon'].concat(orbiterImages.map(function (_, i) { return 'disc' + i; }))
                                       .concat(cloudImages.map(function (_, i) { return 'cloud' + i; }));
              for (var i = 0; i < names.length; i++) {
                out.push(labels[i] + '=' + (names[i].complete ? 'complete' : 'pending') + '/' + names[i].naturalWidth);
              }
              return out.join('  ');
            })()
            """
            view.evaluateJavaScript(script) { value, error in
                print("  sprites: \(value as? String ?? "eval failed: \(error.map(String.init(describing:)) ?? "")")")
                exit(0)
            }
        }
        view.load(page: page)
        keepAlive(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("timed out"); exit(3) }
    }
}
