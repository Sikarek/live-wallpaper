// SelfTest.swift — `--self-test`: end-to-end checks for the things that are easy to get wrong:
// exact geometry on every display, wallpapers adapting to each display's resolution, per-display
// assignment, animation phase sync, and re-laying out when the display configuration changes.
//
// Exit code 0 = every check passed, 1 = at least one failure. Results go to NSLog.

import AppKit

extension AppDelegate {

    func runSelfTest() {
        var results: [String] = []
        let originalSync = Prefs.syncDisplays
        let originalAssignments = Prefs.assignments

        func record(_ ok: Bool, _ name: String, _ detail: String = "") {
            results.append("\(ok ? "PASS" : "FAIL") | \(name)\(detail.isEmpty ? "" : " | " + detail)")
        }
        func finish() {
            Prefs.syncDisplays = originalSync
            Prefs.assignments = originalAssignments
            let failures = results.filter { $0.hasPrefix("FAIL") }.count
            NSLog("LIVEWALLPAPER selftest steps=\(results.count) failures=\(failures)")
            for line in results { NSLog("LIVEWALLPAPER selftest \(line)") }
            NSLog("LIVEWALLPAPER selftest \(failures == 0 ? "ALL CHECKS PASSED" : "FAILURES PRESENT")")
            exit(failures == 0 ? 0 : 1)
        }
        func after(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        func object(_ text: String) -> [String: Any] {
            guard let data = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return dict
        }
        func probe(_ done: @escaping ([[String: Any]]) -> Void) {
            host.probe { entries in
                done(entries.map { entry in
                    var info = object(entry.info)
                    info["display"] = Int(entry.display)
                    info["label"] = entry.label
                    return info
                })
            }
        }
        /// Same as probe, but for one display and re-tried until the page/layer actually answers.
        func probeSlot(_ display: CGDirectDisplayID, tries: Int = 4, _ done: @escaping ([String: Any]) -> Void) {
            host.probe { entries in
                let entry = entries.first { $0.display == display }
                let info = entry.map { object($0.info) } ?? [:]
                if info["w"] != nil || info["layer"] != nil || tries <= 1 { return done(info) }
                after(0.6) { probeSlot(display, tries: tries - 1, done) }
            }
        }
        /// Pages need a moment to load and receive the injected script; retry instead of reading too early.
        func probeWithRetry(_ tries: Int, _ done: @escaping ([[String: Any]]) -> Void) {
            probe { infos in
                let usable = infos.contains { $0["url"] != nil || $0["video"] as? Bool == true }
                if usable || tries <= 1 { return done(infos) }
                after(1.5) { probeWithRetry(tries - 1, done) }
            }
        }
        func slot(for info: [String: Any]) -> ScreenSlot? {
            guard let id = info["display"] as? Int else { return nil }
            return host.slots.first { Int($0.displayID) == id }
        }
        func within(_ value: Int?, _ expected: CGFloat, _ tolerance: Int) -> Bool {
            guard let value else { return false }
            return abs(value - Int(expected)) <= tolerance
        }

        typealias Step = (@escaping () -> Void) -> Void
        var steps: [Step] = []

        // 1. one window per display, exactly the display's frame, at the desktop level
        steps.append { next in
            after(3.0) {
                let screens = NSScreen.screens
                record(self.host.slots.count == screens.count, "one window per display",
                       "windows=\(self.host.slots.count) displays=\(screens.count)")
                var ok = true, detail = ""
                for slot in self.host.slots {
                    let captured = slot.screen.frame
                    let fresh = screens.first { WallpaperHost.displayID(of: $0) == slot.displayID }?.frame ?? .zero
                    let window = slot.window.frame
                    let windowScreen = slot.window.screen?.frame ?? .zero
                    let matches = abs(fresh.minX - window.minX) < 1 && abs(fresh.minY - window.minY) < 1
                        && abs(fresh.width - window.width) < 1 && abs(fresh.height - window.height) < 1
                    if !matches { ok = false }
                    detail += "[\(slot.screen.localizedName) fresh \(NSStringFromRect(fresh)) " +
                              "captured \(NSStringFromRect(captured)) window \(NSStringFromRect(window)) " +
                              "window.screen \(NSStringFromRect(windowScreen)) level=\(slot.window.level.rawValue)] "
                }
                record(ok, "window frame matches each display", detail)
                next()
            }
        }

        // 2. each wallpaper is laid out at its own display's size, and phases line up
        steps.append { next in
            probeWithRetry(4) { infos in
                var ok = true, detail = "", phases: [Int] = []
                for info in infos {
                    guard let slot = self.host.slots.first(where: { Int($0.displayID) == info["display"] as? Int }) else { continue }
                    let expectW = slot.screen.frame.width, expectH = slot.screen.frame.height
                    if let w = info["w"] as? Int, let h = info["h"] as? Int {
                        if !within(w, expectW, 2) || !within(h, expectH, 2) { ok = false }
                        detail += "[\(slot.screen.localizedName) page \(w)x\(h) display \(Int(expectW))x\(Int(expectH)) " +
                                  "dpr=\(info["dpr"] ?? "?") scale-var=\(info["cssW"] ?? "?")] "
                    } else if info["video"] as? Bool == true {
                        detail += "[\(slot.screen.localizedName) video layer \(info["layer"] ?? "?")] "
                    }
                    if let anim = info["anim"] as? [Int], let first = anim.first { phases.append(first) }
                }
                record(ok, "wallpaper adapts to each display's resolution", detail)
                let spread = (phases.max() ?? 0) - (phases.min() ?? 0)
                record(phases.count < 2 || spread <= 100, "animation phase in sync across displays",
                       "spread=\(spread)ms phases=\(phases)")
                next()
            }
        }

        // 3. per-display wallpapers: different wallpaper on alternating displays
        steps.append { next in
            let usable = self.model.wallpapers.filter { $0.kind != .image }
            guard usable.count >= 2, self.host.slots.count >= 2 else {
                record(true, "per-display wallpapers", "skipped: needs >= 2 displays and >= 2 non-image wallpapers")
                return next()
            }
            let first = usable[0].name, second = usable[1].name
            var assignments: [String: String] = [:]
            for (index, slot) in self.host.slots.enumerated() {
                assignments[String(slot.displayID)] = (index % 2 == 0) ? first : second
            }
            Prefs.syncDisplays = false
            Prefs.assignments = assignments
            self.model.syncDisplays = false
            self.model.assignments = assignments
            self.applyPlan()
            after(5.0) {
                probeWithRetry(4) { infos in
                    var ok = true, detail = "", seen = Set<String>()
                    for info in infos {
                        let id = String(info["display"] as? Int ?? -1)
                        let expected = assignments[id] ?? "?"
                        let loaded = (info["url"] as? String) ?? "?"
                        seen.insert(expected)
                        if !loaded.lowercased().contains(expected.lowercased()) { ok = false }
                        detail += "[display \(id) expected=\(expected) loaded=\(loaded)] "
                    }
                    record(ok, "each display shows the wallpaper assigned to it", detail)
                    record(seen.count >= 2, "two different wallpapers live at the same time",
                           "distinct=\(seen.sorted())")
                    next()
                }
            }
        }

        // 4. back to sync mode: one wallpaper everywhere, phases still locked
        steps.append { next in
            Prefs.syncDisplays = true
            self.model.syncDisplays = true
            self.applyPlan()
            after(4.0) {
                probeWithRetry(4) { infos in
                    let urls = Set(infos.compactMap { $0["url"] as? String })
                    record(urls.count <= 1, "sync mode puts the same wallpaper on every display",
                           "loaded=\(urls.sorted())")
                    let phases = infos.compactMap { ($0["anim"] as? [Int])?.first }
                    let spread = (phases.max() ?? 0) - (phases.min() ?? 0)
                    record(phases.count < 2 || spread <= 100, "phases stay locked after a rebuild",
                           "spread=\(spread)ms phases=\(phases)")
                    let videoScreens = self.host.slots.filter { $0.videoLayer != nil }.count
                    if videoScreens > 1 {
                        record(self.host.playerCount == 1, "one shared video player for every display",
                               "players=\(self.host.playerCount) video screens=\(videoScreens)")
                    }
                    next()
                }
            }
        }

        // 5. dynamic resize: what happens when a display changes resolution
        steps.append { next in
            guard let slot = self.host.slots.first else { return next() }
            self.host.geometryHealing = false          // the healer would undo this on purpose-resize
            let original = slot.window.frame
            let newSize = CGSize(width: max(640, original.width - 160), height: max(420, original.height - 120))
            slot.window.setFrame(NSRect(origin: original.origin, size: newSize), display: true)
            after(2.0) {
                probeSlot(slot.displayID) { info in
                    var ok = false, measured = ""
                    if let w = info["w"] as? Int, let h = info["h"] as? Int {
                        ok = within(w, newSize.width, 2) && within(h, newSize.height, 2)
                        measured = "page \(w)x\(h)"
                    } else if let layer = info["layer"] as? String {
                        ok = layer.contains("\(Int(newSize.width))") && layer.contains("\(Int(newSize.height))")
                        measured = "video layer \(layer)"
                    }
                    record(ok, "wallpaper re-fits when its display size changes",
                           "resized to \(Int(newSize.width))x\(Int(newSize.height)), \(measured)")
                    slot.window.setFrame(original, display: true)
                    after(1.5) {
                        probeSlot(slot.displayID) { back in
                            var ok = false, measured = ""
                            if let w = back["w"] as? Int, let h = back["h"] as? Int {
                                ok = within(w, original.width, 2) && within(h, original.height, 2)
                                measured = "page \(w)x\(h)"
                            } else if let layer = back["layer"] as? String {
                                ok = layer.contains("\(Int(original.width))") && layer.contains("\(Int(original.height))")
                                measured = "video layer \(layer)"
                            }
                            record(ok, "restores the display's real size",
                                   "\(measured) expected \(Int(original.width))x\(Int(original.height))")
                            self.host.geometryHealing = true
                            next()
                        }
                    }
                }
            }
        }

        // 6. display-configuration change: rebuild must keep the plan and the geometry
        steps.append { next in
            let before = self.host.slots.map { "\($0.displayID)=\($0.wallpaper.name)" }
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            after(3.0) {
                let after = self.host.slots.map { "\($0.displayID)=\($0.wallpaper.name)" }
                record(Set(before) == Set(after) && before.count == after.count,
                       "display-change rebuild keeps each display's wallpaper",
                       "before=\(before) after=\(after)")
                var ok = true, detail = ""
                for slot in self.host.slots {
                    let screen = slot.screen.frame, window = slot.window.frame
                    let matches = abs(screen.minX - window.minX) < 1 && abs(screen.minY - window.minY) < 1
                        && abs(screen.width - window.width) < 1 && abs(screen.height - window.height) < 1
                    if !matches { ok = false }
                    detail += "[\(slot.screen.localizedName) display \(NSStringFromRect(screen)) window \(NSStringFromRect(window))] "
                }
                record(ok, "windows re-laid out after the display change", detail)
                self.model.refreshDisplays()
                record(self.model.displays.count == NSScreen.screens.count,
                       "settings list matches the current displays",
                       "listed=\(self.model.displays.count) actual=\(NSScreen.screens.count)")
                next()
            }
        }

        // run the steps in order, 0.4 s apart
        func run(_ index: Int) {
            guard index < steps.count else { return finish() }
            let step = steps[index]
            step { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { run(index + 1) } }
        }
        run(0)
    }
}
