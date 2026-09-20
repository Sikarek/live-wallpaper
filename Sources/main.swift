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

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let argv = CommandLine.arguments
        let debugRun = argv.contains("--status") || argv.contains("--seconds") || argv.contains("--dump-ui") || argv.contains("--dump-a11y")

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

        model.refresh(keepSelection: false)
        model.launchAtLogin = LoginItem.isEnabled
        if let saved = UserDefaults.standard.string(forKey: "selected"),
           let match = model.wallpapers.first(where: { $0.name == saved }) {
            apply(match)
        } else if let first = model.wallpapers.first {
            apply(first)
        } else {
            writeStarterNote()
        }
        model.engineChanged(to: host.current?.name, paused: host.paused)

        host.onChange = { [weak self] wallpaper, paused in
            self?.model.engineChanged(to: wallpaper?.name, paused: paused)
        }

        if argv.contains("--status") { reportStatus() }

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

    @objc func screensChanged() {
        host.rebuild()
        model.displayCount = NSScreen.screens.count
    }

    // MARK: model wiring

    private func wireModel() {
        model.onApply = { [weak self] wallpaper in self?.apply(wallpaper) }
        model.onPause = { [weak self] paused in self?.host.setPaused(paused) }
        model.onReload = { [weak self] in self?.host.rebuild() }
        model.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([wallpapersDir]) }
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
            let wasCurrent = (wallpaper.name == self.host.current?.name)
            self.model.refresh(keepSelection: false)
            if wasCurrent, let next = self.model.wallpapers.first {
                self.apply(next)
            } else {
                self.model.engineChanged(to: self.host.current?.name, paused: self.host.paused)
            }
            self.model.status = "Removed \(wallpaper.name)"
        }
    }

    private func apply(_ wallpaper: Wallpaper) {
        UserDefaults.standard.set(wallpaper.name, forKey: "selected")
        host.show(wallpaper)
        model.refresh()
        model.engineChanged(to: wallpaper.name, paused: host.paused)
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
        model.displayCount = NSScreen.screens.count
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
            item.state = (wallpaper.name == host.current?.name) ? .on : .off
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
              let wallpaper = Library.scan().first(where: { $0.name == name }) else { return }
        apply(wallpaper)
        rebuildMenu()
    }

    @objc private func togglePause() {
        host.setPaused(!host.paused)
        rebuildMenu()
    }

    @objc private func reload() {
        host.rebuild()
        rebuildMenu()
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
        host.teardown()
        NSApp.terminate(nil)
    }

    // MARK: debug / verification

    func reportStatus() {
        NSLog("LIVEWALLPAPER level=\(WallpaperHost.level) desktopIcon=\(Int(CGWindowLevelForKey(.desktopIconWindow))) screens=\(NSScreen.screens.count) wallpaper=\(host.current?.name ?? "none") wallpapers=\(model.wallpapers.count)")
        for line in host.statusLines() { NSLog("LIVEWALLPAPER window \(line)") }
        if let button = statusItem?.button {
            let win = button.window.map { NSStringFromRect($0.frame) } ?? "nil"
            NSLog("LIVEWALLPAPER statusItem button=\(NSStringFromRect(button.frame)) window=\(win) hidden=\(button.isHidden) menuItems=\(statusItem.menu?.items.count ?? -1)")
        } else {
            NSLog("LIVEWALLPAPER statusItem MISSING")
        }
        guard CommandLine.arguments.contains("--status") else { return }
        host.probeWeb { lines in
            for line in lines { NSLog("LIVEWALLPAPER \(line)") }
            if let w = self.window {
                NSLog("LIVEWALLPAPER gui window frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible) contentView=\(type(of: w.contentView!))")
            }
            NSApp.terminate(nil)
        }
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
