// main.swift — app delegate, menu-bar item, window management, entry point.
//
// LiveWallpaper: a menu-bar macOS app with a real GUI window (list + live preview + settings) that
// plays an HTML page, a looping video, or an image behind your desktop icons.
//
// Debug flags (used by the test harness):
//   --status              print window levels / status item / what each page rendered, then exit
//   --seconds N           quit after N seconds
//   --dump-ui <path.png>  render the GUI window to a PNG, then exit

import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    let host = WallpaperHost()
    let model = AppModel()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var activity: NSObjectProtocol?
    /// the display layout we last built windows for, to ignore spurious change notifications
    var lastLayoutSignature = ""

/// `tools/lockscreen.py` — installs/restores the aerial slot. Bundled inside this app so quitting can
/// hand the system wallpaper back even if the repository has moved.
enum LockscreenTool {
    static var path: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("tools/lockscreen.py").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/live-wallpaper/tools/lockscreen.py").path
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

    // MARK: the system wallpaper

    private var lockscreenDir: URL { appSupport.appendingPathComponent("lockscreen", isDirectory: true) }
    private var aerialMarker: URL { lockscreenDir.appendingPathComponent("aerial-slot.json") }

    /// Hand the aerial slot back to Apple. Only when OUR clip is in it (the marker records that).
    ///
    /// This is what keeps quitting tidy: while the wallpaper windows are up they cover the system
    /// wallpaper, but a *replaced* aerial (a non-Apple video) renders BLACK on the naked desktop, so
    /// quitting without restoring leaves a black screen. `--restore` puts Apple's own video and still
    /// back and clears the marker, so the desktop and the Lock Screen return to normal.
    @discardableResult
    private func handBackSystemWallpaper(reason: String) -> Bool {
        guard FileManager.default.fileExists(atPath: aerialMarker.path) else { return false }
        guard let tool = LockscreenTool.path else {
            NSLog("LIVEWALLPAPER (\(reason)) lockscreen.py not found — the system wallpaper stays replaced")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [tool, "--restore"]
        do { try task.run() } catch {
            NSLog("LIVEWALLPAPER (\(reason)) could not run \(tool): \(error.localizedDescription)")
            return false
        }
        task.waitUntilExit()
        NSLog("LIVEWALLPAPER (\(reason)) restored Apple's aerial (exit \(task.terminationStatus)) — "
              + "the desktop goes back to the normal wallpaper")
        return task.terminationStatus == 0
    }

    private var syncLastNote = ""

    /// Keep the Lock Screen in step with the desktop: if a clip has been rendered for this wallpaper
    /// (the Composer writes <name>.mov), install it into the slot when it is not already the one there.
    private func syncLockScreenClip(for name: String?) {
        guard let name, !name.isEmpty else { syncLastNote = ""; return }
        let clip = lockscreenDir.appendingPathComponent("\(name).mov")
        guard FileManager.default.fileExists(atPath: clip.path) else {
            syncLastNote = "Lock Screen: no clip rendered for “\(name)” yet — use Render & Install in "
                + "the Starbound Composer (Apple's wallpaper stays until then)"
            return
        }
        if let data = try? Data(contentsOf: aerialMarker),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["video"] as? String) == clip.path {
            syncLastNote = "Lock Screen: showing \(name).mov (already installed)"
            return                                   // already the clip in the slot
        }
        guard let tool = LockscreenTool.path else {
            syncLastNote = "Lock Screen: lockscreen.py not found"
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [tool, "--install", clip.path]
        do { try task.run() } catch { return }
        task.waitUntilExit()
        let ok = task.terminationStatus == 0
        syncLastNote = ok ? "Lock Screen: showing \(name).mov (just installed)"
                          : "Lock Screen: could not install \(name).mov (is the clip still rendering?)"
        NSLog("LIVEWALLPAPER lock screen: installed \(name).mov (exit \(task.terminationStatus))")
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // A wallpaper looks like a background app to macOS: without this, App Nap throttles the
        // timers/WebKit and automatic termination can kill us — which shows up as the wallpaper
        // freezing, or vanishing back to the Mac wallpaper.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled,
                      .suddenTerminationDisabled],
            reason: "Live wallpaper is on screen")

        let argv = CommandLine.arguments
        let debugRun = argv.contains("--set-target") || argv.contains("--simulate-phase")
            || argv.contains("--simulate-covered") || argv.contains("--pause-test")
            || argv.contains("--status") || argv.contains("--seconds") || argv.contains("--dump-ui")
            || argv.contains("--dump-a11y") || argv.contains("--restore-wallpaper") || argv.contains("--self-test") || argv.contains("--watch") || argv.contains("--simulate-lock")

        // One instance only: two of these would stack two sets of wallpaper windows.
        if !debugRun, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.sikarek.livewallpaper.ping"), object: nil, userInfo: nil,
                deliverImmediately: true)
            exit(0)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                              name: NSApplication.didChangeScreenParametersNotification,
                                              object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                              name: NSApplication.didChangeOcclusionStateNotification,
                                              object: nil)
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.host.updateOcclusion()
        }
        // A second launch (Finder double-click, `open`) asks the running instance to show itself.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sikarek.livewallpaper.ping"), object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow(nil) }

        // The Composer posts these after it writes a combination into the wallpaper library: one says
        // "rescan your library", the other also means "put it on screen" (its Export & Use Now).
        // Without these the exported wallpaper would only appear after a manual reload.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sikarek.livewallpaper.refresh"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.model.refresh(keepSelection: true)
            self.model.status = "Composer exported a wallpaper — library reloaded"
            NSLog("LIVEWALLPAPER composer refresh: library now holds \(self.model.wallpapers.count) wallpapers")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sikarek.livewallpaper.apply"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // re-read the shared preferences: the Composer and the menu both write them, and a change
            // made while we were running has to be picked up here or "apply" quietly keeps the old mode
            self.model.target = Target(rawValue: Prefs.target) ?? .both
            self.model.syncDisplays = Prefs.syncDisplays
            self.model.refresh(keepSelection: true)
            if let selected = Prefs.selected, self.model.wallpapers.contains(where: { $0.name == selected }) {
                self.model.selectedName = selected
            }
            self.applyPlan()
            self.model.status = "Applied the wallpaper the Composer exported"
            NSLog("LIVEWALLPAPER composer apply: now showing \(Prefs.selected ?? "<none>") on \(NSScreen.screens.count) display(s)")
        }

        wireModel()
        buildStatusItem()
        watchLockForAerialFreeze()

        model.refresh(keepSelection: false)
        model.refreshDisplays()
        model.launchAtLogin = LoginItem.isEnabled
        model.target = Target(rawValue: Prefs.target) ?? .both
        // --wallpaper <name> overrides the saved choice (handy for tests and scripting)
        if let i = argv.firstIndex(of: "--wallpaper"), i + 1 < argv.count {
            Prefs.selected = argv[i + 1]
        }
        model.syncDisplays = Prefs.syncDisplays
        model.assignments = Prefs.assignments
        if model.wallpapers.isEmpty {
            writeStarterNote()
        } else {
            applyPlan()
        }

        applicationTerminationHook()

        host.onChange = { [weak self] in self?.syncModel() }
        host.onGeometryMismatch = { [weak self] in
            // last resort: rebuild every window from the fresh display list
            self?.applyPlan()
        }

        if argv.contains("--watch") {
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                n += 1
                self.host.probe { entries in
                    for e in entries {
                        NSLog("LIVEWALLPAPER watch t=\(n * 2)s \(e.label) \(e.info)")
                    }
                }
            }
        }
        if argv.contains("--simulate-phase") {
            // the phase alignment, without a real lock: note a lock, wait, then unlock and report what
            // the page's star rotation became (it should be ~2pi * waited / dayLength)
            noteScreenLocked()
            let waited = Double(argv.firstIndex(of: "--simulate-phase").flatMap { index in
                index + 1 < argv.count ? Double(argv[index + 1]) : nil
            } ?? 4.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + waited) {
                self.alignDesktopPhaseWithLockScreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.host.probe { entries in
                        for entry in entries {
                            NSLog("LIVEWALLPAPER simulate-phase: \(entry.label) \(entry.info)")
                        }
                        exit(0)
                    }
                }
            }
        }
        if argv.contains("--simulate-lock") {
            // what the unlock/wake observers do (used by the tests)
            let marker = appSupport.appendingPathComponent("lockscreen/aerial-slot.json")
            NSLog("LIVEWALLPAPER simulate-lock: marker exists = \(FileManager.default.fileExists(atPath: marker.path))")
            self.refreshAerialPipeline(reason: "simulate-unlock")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                let ext = Process()
                ext.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                ext.arguments = ["-f", "WallpaperAerialsExtension"]
                let pipe = Pipe()
                ext.standardOutput = pipe
                try? ext.run()
                ext.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("LIVEWALLPAPER simulate-lock: aerials extension running = \(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
                exit(0)
            }
        }
        if argv.contains("--status") { reportStatus() }
        if argv.contains("--self-test") { runSelfTest() }
        if argv.contains("--restore-wallpaper") { restoreAndExit() }
        if argv.contains("--pause-test") {
            // Pause and resume ONE visible display and watch its own frame counter. This has to run here,
            // in a real on-screen window: an off-screen WKWebView never delivers requestAnimationFrame, so
            // a probe tool cannot exercise the animated path at all (it silently measures the still branch).
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                guard let display = self.host.slots.first?.displayID else {
                    print("no slot"); exit(2)
                }
                self.host.readCost(display: display) { before in
                    print("  before pause: \(before)")
                    self.host.setDrawing(false, display: display)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.host.readCost(display: display) { paused in
                            print("  after 2 s paused: \(paused)")
                            self.host.setDrawing(true, display: display)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                self.host.readCost(display: display) { resumed in
                                    print("  after 2 s resumed: \(resumed)")
                                    let froze = (paused["drawn"] as? Int ?? -1) == (before["drawn"] as? Int ?? -2)
                                    let slept = (paused["sleeping"] as? Bool) == true
                                    let woke = (resumed["sleeping"] as? Bool) == false
                                    let advanced = (resumed["drawn"] as? Int ?? 0) > (paused["drawn"] as? Int ?? 0)
                                    print(froze && slept && woke && advanced
                                          ? "PAUSE/RESUME OK — paused stopped the loop, resumed restarted it"
                                          : "PAUSE/RESUME BROKEN (froze=\(froze) slept=\(slept) woke=\(woke) advanced=\(advanced))")
                                    exit(froze && slept && woke && advanced ? 0 : 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        if argv.contains("--simulate-covered") {
            // prove the covered-window path without needing to cover the desktop
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                for slot in self.host.slots { self.host.setDrawing(false, display: slot.displayID) }
                NSLog("LIVEWALLPAPER simulate-covered: drawing off on \(self.host.slots.count) display(s)")
                // measure it: the drawn-frame counter must stop advancing while drawing is off
                self.host.probe { entries in
                    for entry in entries { NSLog("LIVEWALLPAPER covered t0: \(entry.label) \(entry.info)") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.host.probe { entries in
                        for entry in entries { NSLog("LIVEWALLPAPER covered t3: \(entry.label) \(entry.info)") }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    for slot in self.host.slots { self.host.setDrawing(true, display: slot.displayID) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.host.probe { entries in
                            for entry in entries {
                                NSLog("LIVEWALLPAPER simulate-covered resume: \(entry.label) \(entry.info)")
                            }
                            exit(0)
                        }
                    }
                }
            }
        }
        if let i = argv.firstIndex(of: "--set-target"), i + 1 < argv.count,
           let option = Target(rawValue: argv[i + 1]) {
            Prefs.target = option.rawValue
            model.target = option
            applyPlan()
            NSLog("LIVEWALLPAPER set-target \(option.rawValue): windows=\(host.slots.count) "
                  + "note=\(model.lockScreenNote)")
            print("target=\(option.rawValue) windows=\(host.slots.count) \(model.lockScreenNote)")
            exit(0)
        }

        if let i = argv.firstIndex(of: "--dump-ui"), i + 1 < argv.count {
            showWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.dumpUI(argv[i + 1]) }
        } else if argv.contains("--dump-a11y") {
            showWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.dumpAccessibility() }
        } else if !debugRun, !UserDefaults.standard.bool(forKey: "seenIntro") {
            UserDefaults.standard.set(true, forKey: "seenIntro")
            showWindow(nil)
        }
    }

    /// LaunchServices hands a re-launch to the running instance only if we implement this;
    /// without it `open LiveWallpaper.app` fails with -10825 while an instance is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    /// macOS 26+ has a bug in WallpaperExtensionKit: a *custom* aerial video plays once and then
    /// freezes / goes static on every later lock (Apple's own aerials take a different code path
    /// inside ShuffleWallpaper and are unaffected).
    ///
    /// The fix is to give the pipeline a fresh player — but restart the *agent*, not the extension:
    /// killing WallpaperAerialsExtension leaves the lock screen with no renderer at all, and macOS
    /// then falls back to a default static picture. `killall WallpaperAgent` re-exports the wallpaper
    /// and respawns the extension within ~2 s (verified), which is what this does on unlock and on
    /// wake from sleep — never while the lock screen is up.
    /// Only done when OUR video is in the aerial slot (that is what the marker file records).
    private func watchLockForAerialFreeze() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAerialPipeline(reason: "unlock")
            self?.alignDesktopPhaseWithLockScreen()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.noteScreenLocked()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Waking from sleep lands you ON the lock screen: restarting the wallpaper agent here
            // would take the renderer away from the screen you are looking at. The unlock
            // notification that follows will do the refresh instead.
            if Self.screenIsLocked() {
                NSLog("LIVEWALLPAPER (wake) screen is locked — the aerial is refreshed on unlock instead")
            } else {
                self?.refreshAerialPipeline(reason: "wake from sleep")
            }
            // and make sure our own windows survived the sleep
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let missing = self.host.slots.contains { !$0.window.isVisible }
                if missing {
                    NSLog("LIVEWALLPAPER (wake) \(self.host.slots.filter { !$0.window.isVisible }.count) wallpaper window(s) gone — rebuilding")
                    self.applyPlan()
                }
            }
        }
    }

    /// Is the screen locked right now? (CGSessionCopyCurrentDictionary is the supported way.)
    /// When the screen locked, recorded so the desktop can be put at the phase the clip will be at.
    private var lockedAt: Date?

    func noteScreenLocked() {
        lockedAt = Date()
        // The Lock Screen clip always plays from the start of the sky's day, because the extension is
        // restarted on every lock (the freeze workaround). So put the desktop there too, at the moment
        // the display goes dark: the two surfaces are then at the same position, and the lock screen
        // continues smoothly from the sky the desktop was showing instead of jumping somewhere else.
        // With the power button the panel is already off; with ctrl-cmd-Q this lands during the fade.
        if model.target.showsDesktop { host.setPhase(seconds: 0) }
        NSLog("LIVEWALLPAPER screen locked — desktop moved to the clip's start so both agree")
    }

    /// The clip restarts at its first frame on every lock, so "how long has the lock screen been playing"
    /// is simply "how long ago did the screen lock". Nothing to align unless we saw the lock.
    private func alignDesktopPhaseWithLockScreen() {
        guard model.target.showsDesktop, let lockedAt else { return }
        let elapsed = Date().timeIntervalSince(lockedAt)
        self.lockedAt = nil
        host.setPhase(seconds: elapsed)
        NSLog("LIVEWALLPAPER phase sync: clip has been playing \(Int(elapsed))s — desktop aligned to it")
    }

    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Restart WallpaperAgent (which re-exports the wallpaper and respawns its extension) — only when
    /// our own video is the one in the slot, recorded by tools/lockscreen.py --install.
    func refreshAerialPipeline(reason: String) {
        let marker = appSupport.appendingPathComponent("lockscreen/aerial-slot.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            NSLog("LIVEWALLPAPER (\(reason)) no aerial marker — leaving the system wallpaper alone")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        do {
            try task.run()
            task.waitUntilExit()
            NSLog("LIVEWALLPAPER (\(reason)) restarted WallpaperAgent so the custom aerial keeps animating")
        } catch {
            NSLog("LIVEWALLPAPER (\(reason)) could not restart the wallpaper agent: \(error.localizedDescription)")
        }
    }

    /// Any change to the display layout — count, resolution, arrangement — rebuilds every window from
    /// the current screen list, so each display keeps its own wallpaper at its own new geometry.
    /// macOS also fires this notification spuriously (observed every ~2 s on this machine); acting on
    /// those re-created every window and reloaded every page, which is what made the desktop picture
    /// flash back. So: only rebuild when the layout actually differs from what we laid out.
    @objc func screensChanged() {
        let signature = screenSignature()
        guard signature != lastLayoutSignature else { return }
        lastLayoutSignature = signature
        NSLog("LIVEWALLPAPER displays changed: \(signature)")
        model.refreshDisplays()
        applyPlan()
    }

    func screenSignature() -> String {
        NSScreen.screens.map { screen in
            "\(WallpaperHost.displayID(of: screen))@\(NSStringFromRect(screen.frame))x\(screen.backingScaleFactor)"
        }.sorted().joined(separator: "|")
    }

    // MARK: model wiring

    private func wireModel() {
        model.onApply = { [weak self] wallpaper in
            Prefs.selected = wallpaper.name
            Prefs.syncDisplays = true
            self?.model.syncDisplays = true
            self?.applyPlan()
        }
        model.onPause = { [weak self] paused in self?.host.setPaused(paused) }
        model.onReload = { [weak self] in self?.applyPlan() }
        model.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([wallpapersDir]) }
        model.onTarget = { [weak self] target in
            Prefs.target = target.rawValue
            self?.applyPlan()
        }
        model.onSyncDisplays = { [weak self] sync in
            Prefs.syncDisplays = sync
            self?.model.syncDisplays = sync
            self?.applyPlan()
        }
        model.onAssign = { [weak self] display, name in
            guard let self else { return }
            var assignments = Prefs.assignments
            assignments[String(display)] = name
            Prefs.assignments = assignments
            self.model.assignments = assignments
            self.applyPlan()
        }
        model.onLaunchAtLogin = { [weak self] want in
            let actual = LoginItem.set(want)
            self?.model.launchAtLogin = actual
            self?.model.status = (actual == want) ? ""
                : "macOS refused the login item — move the app to ~/Applications and try again."
        }
        model.onAdd = { [weak self] url in
            guard let self else { return }
            if let added = Library.adopt(url) {
                self.model.refresh(keepSelection: false)
                let name = added.deletingPathExtension().lastPathComponent
                self.model.selectedName = self.model.wallpapers.first { $0.name == name }?.name
                    ?? self.model.wallpapers.last?.name
                self.model.status = "Added \(added.lastPathComponent)"
            }
        }
        model.onRemove = { [weak self] wallpaper in
            guard let self else { return }
            Library.remove(wallpaper)
            var assignments = Prefs.assignments
            for (key, value) in assignments where value == wallpaper.name { assignments[key] = nil }
            Prefs.assignments = assignments
            if Prefs.selected == wallpaper.name { Prefs.selected = nil }
            self.model.assignments = assignments
            self.model.refresh(keepSelection: false)
            self.applyPlan()
            self.model.status = "Removed \(wallpaper.name)"
        }
    }

    /// The per-display plan: in sync mode every display gets the one chosen wallpaper; otherwise each
    /// display falls back to its own assignment, then the sync choice, then the first in the library.
    private func resolvePlan() -> [(screen: NSScreen, wallpaper: Wallpaper)] {
        let syncWallpaper = model.wallpapers.first { $0.name == Prefs.selected } ?? model.wallpapers.first
        var plan: [(screen: NSScreen, wallpaper: Wallpaper)] = []
        for screen in NSScreen.screens {
            var wallpaper = syncWallpaper
            if !Prefs.syncDisplays,
               let name = Prefs.assignments[String(WallpaperHost.displayID(of: screen))],
               let match = model.wallpapers.first(where: { $0.name == name }) {
                wallpaper = match
            }
            guard let chosen = wallpaper else { continue }
            plan.append((screen, chosen))
        }
        return plan
    }

    func applyPlan() {
        let plan = resolvePlan()
        guard !plan.isEmpty else { return }
        lastLayoutSignature = screenSignature()     // remember what we laid out for
        if model.target.showsDesktop {
            host.show(plan)                         // our own windows on the desktop
        } else {
            host.teardown()                         // desktop untouched: the system wallpaper shows
        }
        syncModel()
        rebuildMenu()
        applyLockScreenSide(name: plan.first?.wallpaper.name)
    }

    /// The Lock Screen half of the target: put the clip rendered for this wallpaper into the aerial
    /// slot, or hand the slot back to Apple when the Lock Screen is not part of the target.
    private func applyLockScreenSide(name: String?) {
        if model.target.showsLockScreen {
            syncLockScreenClip(for: name)
            model.lockScreenNote = syncLastNote
        } else {
            handBackSystemWallpaper(reason: "target=\(model.target.rawValue)")
            model.lockScreenNote = "Lock Screen: Apple's own wallpaper (not part of the target)"
        }
    }

    /// Any quit — the menu, ⌘Q, a logout — has to hand the aerial slot back, or the desktop is left
    /// showing a replaced (and therefore black) system wallpaper. SIGTERM is covered separately because
    /// a signal does not run AppKit's termination path (launchctl bootout and `pkill` use it).
    private func applicationTerminationHook() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.handBackSystemWallpaper(reason: "quit")
        }
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { [weak self] in
            self?.handBackSystemWallpaper(reason: "SIGTERM")
            exit(0)
        }
        signalSource.resume()
        Self.signalSource = signalSource            // must stay alive for the handler to fire
        signal(SIGTERM, SIG_IGN)                    // …and the default action must be off
    }

    private static var signalSource: DispatchSourceSignal?

    /// Mirror what the engine currently has on screen into the UI model.
    func syncModel() {
        var current: [CGDirectDisplayID: String] = [:]
        for slot in host.slots { current[slot.displayID] = slot.wallpaper.name }
        model.engineChanged(current: current, paused: host.paused)
    }

    private func writeStarterNote() {
        let note = wallpapersDir.appendingPathComponent("README.txt")
        let text = """
        Drop a wallpaper in here:
          - a FOLDER containing index.html  (HTML/CSS/JS — canvas animations work)
          - a video (.mp4/.mov/.m4v) — loops, muted
          - an image (.png/.jpg/.heic/.gif) — gets a slow Ken-Burns drift
        Then pick it in the LiveWallpaper window (or the menu-bar item).
        """
        try? text.write(to: note, atomically: true, encoding: .utf8)
    }

    // MARK: window

    @objc func showWindow(_ sender: Any?) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "LiveWallpaper"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: ContentView(model: model))
            w.setFrameAutosaveName("LiveWallpaperWindow")
            w.center()
            window = w
        }
        model.refreshDisplays()
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LiveWallpaper")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = img == nil ? "LW" : ""      // never leave an invisible item
        statusItem.button?.toolTip = "LiveWallpaper"
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "LiveWallpaper Settings…", action: #selector(showWindow(_:)), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        model.refresh()
        if model.wallpapers.isEmpty {
            let empty = NSMenuItem(title: "No wallpapers yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for wallpaper in model.wallpapers {
            let item = NSMenuItem(title: wallpaper.name, action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = wallpaper.name
            item.state = model.isOnScreen(wallpaper.name) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let targetItem = NSMenuItem(title: "Show the wallpaper on", action: nil, keyEquivalent: "")
        let targetMenu = NSMenu()
        for option in Target.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(setTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (Prefs.target == option.rawValue) ? .on : .off
            targetMenu.addItem(item)
        }
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)
        menu.addItem(.separator())

        let pause = NSMenuItem(title: host.paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let reload = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let reveal = NSMenuItem(title: "Open Wallpapers Folder", action: #selector(reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LiveWallpaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              Library.scan().contains(where: { $0.name == name }) else { return }
        Prefs.selected = name
        Prefs.syncDisplays = true
        model.syncDisplays = true
        applyPlan()
    }

    @objc private func togglePause() {
        host.setPaused(!host.paused)
        rebuildMenu()
    }

    @objc private func reload() {
        applyPlan()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([wallpapersDir])
    }

    @objc private func occlusionChanged() {
        host.updateOcclusion()
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Target(rawValue: raw) else { return }
        Prefs.target = raw
        model.target = option
        applyPlan()
        NSLog("LIVEWALLPAPER target = \(raw) — desktop \(option.showsDesktop ? "on" : "off"), "
              + "lock screen \(option.showsLockScreen ? "on" : "off")")
    }

    @objc private func toggleLogin() {
        _ = LoginItem.set(!LoginItem.isEnabled)
        model.launchAtLogin = LoginItem.isEnabled
        rebuildMenu()
    }

    @objc private func quit() {
        // If this instance is owned by the login LaunchAgent, deregister it first — otherwise
        // KeepAlive would immediately start the wallpaper again.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/com.sikarek.livewallpaper"]
        try? task.run()
        task.waitUntilExit()

        host.teardown()
        NSApp.terminate(nil)
    }

    // MARK: debug / verification

    /// `--restore-wallpaper`: hand the slot back and exit (what quitting does; scriptable).
    func restoreAndExit() {
        let restored = handBackSystemWallpaper(reason: "--restore-wallpaper")
        print(restored ? "restored Apple's aerial" : "nothing of ours was in the slot")
        exit(restored ? 0 : 2)
    }

    func reportStatus() {
        NSLog("LIVEWALLPAPER level=\(WallpaperHost.level) desktopIcon=\(Int(CGWindowLevelForKey(.desktopIconWindow))) screens=\(NSScreen.screens.count) windows=\(host.slots.count) sync=\(Prefs.syncDisplays) library=\(model.wallpapers.count)")
        for line in host.statusLines() { NSLog("LIVEWALLPAPER slot \(line)") }
        for (display, paused) in host.drawingPaused {
            NSLog("LIVEWALLPAPER display \(display) drawing \(paused ? "OFF (covered)" : "on")")
        }
        NSLog("LIVEWALLPAPER occlusion: " + host.slots.map {
            "\($0.displayID)=\($0.window.occlusionState.contains(.visible) ? "visible" : "covered")"
        }.joined(separator: " "))
        if let button = statusItem?.button {
            let win = button.window.map { NSStringFromRect($0.frame) } ?? "nil"
            NSLog("LIVEWALLPAPER statusItem button=\(NSStringFromRect(button.frame)) window=\(win) hidden=\(button.isHidden) menuItems=\(statusItem.menu?.items.count ?? -1)")
        } else {
            NSLog("LIVEWALLPAPER statusItem MISSING")
        }
        guard CommandLine.arguments.contains("--status") else { return }
        // pages need a moment to load before they can report anything
        func probeStatus(_ tries: Int) {
            host.probe { entries in
                let usable = entries.contains { !$0.info.contains("no-info") && !$0.info.contains("empty") }
                if !usable, tries > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { probeStatus(tries - 1) }
                    return
                }
                for entry in entries { NSLog("LIVEWALLPAPER page \(entry.label) \(entry.info)") }
                if let w = self.window {
                    NSLog("LIVEWALLPAPER gui window frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible)")
                }
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { probeStatus(5) }
    }

    /// Render our own window straight to a PNG so the GUI can be inspected without screen recording.
    func dumpUI(_ path: String) {
        guard let view = window?.contentView else {
            NSLog("LIVEWALLPAPER dump-ui: no window")
            exit(1)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("LIVEWALLPAPER dump-ui \(Int(view.bounds.width))x\(Int(view.bounds.height)) -> \(path) (\(data.count) bytes)")
        exit(0)
    }

    /// Print the window's accessibility tree via the system AX API (the same way VoiceOver sees a
    /// SwiftUI window). The reliable way to check that the controls really exist and are laid out.
    func dumpAccessibility() {
        guard let window else {
            NSLog("LIVEWALLPAPER dump-a11y: no window")
            exit(1)
        }
        let appElement = AXUIElementCreateApplication(getpid())
        var lines: [String] = []

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func string(_ element: AXUIElement, _ name: String) -> String {
            (attribute(element, name) as? String) ?? ""
        }
        func rect(_ element: AXUIElement) -> String {
            func read<T>(_ value: CFTypeRef?, _ type: AXValueType, _ into: inout T) -> Bool {
                guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
                return AXValueGetValue(value as! AXValue, type, &into)
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard read(attribute(element, kAXPositionAttribute), .cgPoint, &origin),
                  read(attribute(element, kAXSizeAttribute), .cgSize, &size) else { return "" }
            return "@\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))"
        }

        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            let role = string(element, kAXRoleAttribute)
            let title = string(element, kAXTitleAttribute)
            let description = string(element, kAXDescriptionAttribute)
            let value = attribute(element, kAXValueAttribute).map { "\($0)" } ?? ""
            let name = !title.isEmpty ? title : description
            let interesting = ["AXButton", "AXCheckBox", "AXRadioButton", "AXStaticText", "AXRow",
                               "AXList", "AXScrollArea", "AXTextField", "AXGroup"].contains(role) || !name.isEmpty
            if interesting {
                var line = String(repeating: "· ", count: depth) + "\(role)"
                if !name.isEmpty { line += " \"\(name)\"" }
                if !value.isEmpty { line += " value=\(value)" }
                let frame = rect(element)
                if !frame.isEmpty { line += "  \(frame)" }
                lines.append(line)
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { walk(child, depth + 1) }
            }
        }

        if let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] {
            for w in windows { walk(w, 0) }
        }
        NSLog("LIVEWALLPAPER a11y elements=\(lines.count) window=\(NSStringFromRect(window.frame))")
        for line in lines { NSLog("LIVEWALLPAPER a11y \(line)") }
        exit(0)
    }
}

// MARK: - entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if let i = CommandLine.arguments.firstIndex(of: "--seconds"), i + 1 < CommandLine.arguments.count,
   let secs = Double(CommandLine.arguments[i + 1]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
        NSLog("LIVEWALLPAPER quitting after \(secs)s")
        NSApp.terminate(nil)
    }
}
app.run()
