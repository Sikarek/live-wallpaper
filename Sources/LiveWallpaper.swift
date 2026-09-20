// LiveWallpaper — a menu-bar macOS app that plays a live wallpaper behind your desktop icons.
//
//   swiftc -O -o build/LiveWallpaper Sources/LiveWallpaper.swift     (or ./build.sh)
//
// How it works: one borderless NSWindow per display, parked one window level BELOW
// kCGDesktopIconWindow — above the wallpaper picture, below the icons, below every normal window.
// Content can be an HTML/CSS/JS page (any canvas animation), a looping video, or a still image
// (wrapped in a generated Ken-Burns page). No Apple Developer account, no notarization, no Xcode.
//
// Debug flags (used by the test harness):
//   --status          print what is on screen, then exit
//   --seconds N       quit after N seconds

import AppKit
import AVFoundation
import ServiceManagement
import WebKit

// MARK: - paths

let appSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
let wallpapersDir = appSupport.appendingPathComponent("wallpapers", isDirectory: true)
let wrapperCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/LiveWallpaper", isDirectory: true)

let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]

// MARK: - wallpaper model

enum Content {
    case web(URL)      // HTML page in a WKWebView
    case video(URL)    // looping muted video
}

struct Wallpaper {
    let name: String
    let url: URL
    let content: Content
}

enum Library {

    /// A wallpaper is either a folder (index.html, or a single media file) or a loose media file.
    static func scan() -> [Wallpaper] {
        let fm = FileManager.default
        try? fm.createDirectory(at: wallpapersDir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: wallpapersDir,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return [] }

        var found: [Wallpaper] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let w = fromFolder(entry) { found.append(w) }
            } else if let c = content(for: entry) {
                found.append(Wallpaper(name: entry.deletingPathExtension().lastPathComponent,
                                       url: entry, content: c))
            }
        }
        return found
    }

    private static func fromFolder(_ dir: URL) -> Wallpaper? {
        let fm = FileManager.default
        let index = dir.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) {
            return Wallpaper(name: dir.lastPathComponent, url: index, content: .web(index))
        }
        // no index.html: use the first media file in the folder, alphabetically
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for f in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let c = content(for: f) {
                return Wallpaper(name: dir.lastPathComponent, url: f, content: c)
            }
        }
        return nil
    }

    static func content(for file: URL) -> Content? {
        switch file.pathExtension.lowercased() {
        case "html", "htm":     return .web(file)
        case let e where videoExtensions.contains(e): return .video(file)
        case let e where imageExtensions.contains(e): return .web(wrap(image: file))
        default: return nil
        }
    }

    /// Wrap a still image in a generated page so it gets the same slow Ken-Burns drift.
    private static func wrap(image: URL) -> URL {
        try? FileManager.default.createDirectory(at: wrapperCache, withIntermediateDirectories: true)
        let digest = String(image.path.hashValue.magnitude, radix: 16)
        let out = wrapperCache.appendingPathComponent("img-\(digest).html")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
          html,body{height:100%;margin:0;background:#000;overflow:hidden}
          body{min-width:640px;min-height:420px}
          img{position:fixed;inset:0;width:100%;height:100%;object-fit:cover;
              animation:kb 120s ease-in-out infinite alternate}
          @keyframes kb{from{transform:scale(1.0) translate3d(0,0,0)}
                        to{transform:scale(1.09) translate3d(-1.2%,-0.9%,0)}}
          @media (prefers-reduced-motion:reduce){img{animation:none}}
        </style></head><body><img src="\(image.absoluteString)"></body></html>
        """
        try? html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - window + host

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Host {
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []      // retained per screen — see note below
    private var loopers: [AVPlayerLooper] = []     // AVPlayerLooper deallocates if not retained
    private var webViews: [WKWebView] = []
    private(set) var current: Wallpaper?
    private(set) var paused = false

    static let level = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1

    func show(_ wallpaper: Wallpaper) {
        teardown()
        current = wallpaper
        paused = false
        for screen in NSScreen.screens {
            windows.append(makeWindow(on: screen, wallpaper: wallpaper))
        }
        for w in windows { w.orderFront(nil) }
    }

    func pause(_ pause: Bool) {
        guard let wallpaper = current, pause != paused else { return }
        paused = pause
        if pause {
            for p in players { p.pause() }
            for w in windows { w.orderOut(nil) }
        } else {
            for p in players { p.play() }
            for w in windows { w.orderFront(nil) }
            _ = wallpaper   // video stays decoded; web pages keep their own animation state
        }
    }

    private func makeWindow(on screen: NSScreen, wallpaper: Wallpaper) -> NSWindow {
        let w = WallpaperWindow(contentRect: screen.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Self.level)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false

        switch wallpaper.content {
        case .web(let url):
            let cfg = WKWebViewConfiguration()
            let view = WKWebView(frame: CGRect(origin: .zero, size: screen.frame.size), configuration: cfg)
            view.autoresizingMask = [.width, .height]
            // allow the page to read its sibling assets/ folder
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            webViews.append(view)
            w.contentView = view

        case .video(let url):
            let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            let player = AVQueuePlayer()
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = v.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            v.layer?.addSublayer(layer)
            player.isMuted = true
            player.play()
            players.append(player)
            loopers.append(looper)
            w.contentView = v
        }
        return w
    }

    func teardown() {
        for p in players { p.pause() }
        players.removeAll()
        loopers.removeAll()
        webViews.removeAll()
        for w in windows { w.orderOut(nil); w.contentView = nil }
        windows.removeAll()
    }

    func status() -> [String] {
        windows.map { "frame=\(NSStringFromRect($0.frame)) level=\($0.level.rawValue) visible=\($0.isVisible)" }
    }

    /// Ask each web page what it actually rendered — proof the wallpaper loaded, not just a black window.
    func probeWeb(_ completion: @escaping ([String]) -> Void) {
        guard !webViews.isEmpty else { return completion([]) }
        let js = """
        (function(){
          const stars = document.getElementById('stars');
          window.__probe = 'pending';
          const i = new Image();
          i.onload  = () => { window.__probe = 'asset ' + i.naturalWidth + 'x' + i.naturalHeight; };
          i.onerror = () => { window.__probe = 'asset FAILED'; };
          i.src = 'assets/sector_bg.png';
          return document.title
               + ' | layers=' + document.querySelectorAll('.layer').length
               + ' | anim=' + (stars ? getComputedStyle(stars).animationName : 'no-star-layer')
               + ' | bodyH=' + (document.body ? document.body.offsetHeight : -1);
        })()
        """
        var out: [String] = []
        let group = DispatchGroup()
        for (n, view) in webViews.enumerated() {
            group.enter()
            // give the page a moment to finish loading before interrogating it
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                view.evaluateJavaScript(js) { result, error in
                    let head = (result as? String) ?? "jsError: \(error?.localizedDescription ?? "nil")"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        view.evaluateJavaScript("window.__probe") { probe, _ in
                            out.append("web[\(n)] \(head) | \(probe as? String ?? "?")")
                            group.leave()
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) { completion(out) }
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = Host()
    var statusItem: NSStatusItem!
    var library: [Wallpaper] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Single instance: two of these would stack two sets of wallpaper windows.
        // Skipped for the debug flags, which are meant to run alongside a live instance.
        let debugRun = CommandLine.arguments.contains("--status") || CommandLine.arguments.contains("--seconds")
        if !debugRun, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSLog("LIVEWALLPAPER another instance is already running — exiting")
            exit(0)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                              name: NSApplication.didChangeScreenParametersNotification,
                                              object: nil)
        buildStatusItem()
        library = Library.scan()
        if let saved = UserDefaults.standard.string(forKey: "selected"),
           let match = library.first(where: { $0.name == saved }) {
            host.show(match)
        } else if let first = library.first {
            host.show(first)
            UserDefaults.standard.set(first.name, forKey: "selected")
        } else {
            writeStarterNote()
        }
        if CommandLine.arguments.contains("--status") { reportStatus() }
    }

    @objc func screensChanged() {
        guard let current = host.current else { return }
        host.show(current)
    }

    private func writeStarterNote() {
        let note = wallpapersDir.appendingPathComponent("README.txt")
        let text = """
        Drop a wallpaper in here:
          - a FOLDER containing index.html  (HTML/CSS/JS — canvas animations work)
          - a video (.mp4/.mov/.m4v) — loops, muted
          - an image (.png/.jpg/.heic/.gif) — gets a slow Ken-Burns drift
        Then pick it from the LiveWallpaper menu-bar menu.
        """
        try? text.write(to: note, atomically: true, encoding: .utf8)
    }

    // MARK: menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LiveWallpaper")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "LiveWallpaper"
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "LiveWallpaper", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        library = Library.scan()
        let selected = host.current?.name
        if library.isEmpty {
            let empty = NSMenuItem(title: "No wallpapers yet — see README.txt in the folder", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for w in library {
            let it = NSMenuItem(title: w.name, action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = w.name
            it.state = (w.name == selected) ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let pauseTitle = host.paused ? "Resume" : "Pause"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
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
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LiveWallpaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let w = Library.scan().first(where: { $0.name == name }) else { return }
        UserDefaults.standard.set(name, forKey: "selected")
        host.show(w)
        rebuildMenu()
    }

    @objc private func togglePause() {
        host.pause(!host.paused)
        rebuildMenu()
    }

    @objc private func reload() {
        if let current = host.current {
            host.show(current)
        } else if let first = library.first {
            host.show(first)
        }
        rebuildMenu()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([wallpapersDir])
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("LIVEWALLPAPER login item error: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        host.teardown()
        NSApp.terminate(nil)
    }

    func reportStatus() {
        NSLog("LIVEWALLPAPER level=\(Host.level) desktopIcon=\(Int(CGWindowLevelForKey(.desktopIconWindow))) screens=\(NSScreen.screens.count) wallpaper=\(host.current?.name ?? "none")")
        for line in host.status() { NSLog("LIVEWALLPAPER window \(line)") }
        guard CommandLine.arguments.contains("--status") else { return }
        host.probeWeb { lines in
            for line in lines { NSLog("LIVEWALLPAPER \(line)") }
            NSApp.terminate(nil)
        }
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
