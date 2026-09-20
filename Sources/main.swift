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
        let debugRun = argv.contains("--status") || argv.contains("--seconds") || argv.contains("--dump-ui")
            || argv.contains("--dump-a11y") || argv.contains("--self-test") || argv.contains("--watch") || argv.contains("--simulate-lock")

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
        // A second launch (Finder double-click, `open`) asks the running instance to show itself.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sikarek.livewallpaper.ping"), object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow(nil) }

        wireModel()
        buildStatusItem()
        watchLockForAerialFreeze()

        model.refresh(keepSelection: false)
        model.refreshDisplays()
        model.launchAtLogin = LoginItem.isEnabled
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
        host.show(plan)
        syncModel()
        rebuildMenu()
    }

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

    func reportStatus() {
        NSLog("LIVEWALLPAPER level=\(WallpaperHost.level) desktopIcon=\(Int(CGWindowLevelForKey(.desktopIconWindow))) screens=\(NSScreen.screens.count) windows=\(host.slots.count) sync=\(Prefs.syncDisplays) library=\(model.wallpapers.count)")
        for line in host.statusLines() { NSLog("LIVEWALLPAPER slot \(line)") }
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
