// WallpaperHost.swift — the engine: one borderless window per display, one level below the desktop
// icons. Handles per-display wallpapers, keeps every screen's animation in phase, and re-lays itself
// out whenever the display configuration (count / size / resolution) changes.

import AppKit
import AVFoundation
import WebKit

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Web view that reports when its page finished loading, so the host can inject the sync script.
/// Also self-heals: macOS/WebKit can terminate the content process (memory pressure, suspension),
/// which blanks the desktop until something reloads it.
final class SlotWebView: WKWebView, WKNavigationDelegate {
    var onReady: (() -> Void)?
    private var lastRecovery = Date.distantPast

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onReady?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        NSLog("LIVEWALLPAPER web content terminated — reloading")
        // don't hammer: at most one recovery every 5 s
        guard now.timeIntervalSince(lastRecovery) > 5 else { return }
        lastRecovery = now
        webView.reload()
    }
}

struct ScreenSlot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let window: NSWindow
    let wallpaper: Wallpaper
    var web: SlotWebView?
    var videoLayer: AVPlayerLayer?
}

final class WallpaperHost {

    private(set) var slots: [ScreenSlot] = []

    /// Stop or resume drawing on one display (per display: a window maximised on one monitor should not
    /// keep the other two redrawing). The page's clock keeps running while drawing is off, so the scene
    /// resumes at the right moment instead of being frozen in the past.
    func setDrawing(_ drawing: Bool, display: CGDirectDisplayID) {
        guard let slot = slots.first(where: { $0.displayID == display }), let web = slot.web else { return }
        web.evaluateJavaScript("window.__lwSetPaused && window.__lwSetPaused(\(drawing ? "false" : "true"))",
                               completionHandler: nil)
        drawingPaused[display] = !drawing
    }

    /// Which displays currently have drawing switched off, and why (for --status).
    private(set) var drawingPaused: [CGDirectDisplayID: Bool] = [:]

    /// A covered wallpaper window is invisible work: everything the canvas draws lands behind someone
    /// else's window. macOS reports this per window, so pause exactly those displays.
    func updateOcclusion() {
        for slot in slots {
            let visible = slot.window.occlusionState.contains(.visible)
            setDrawing(visible, display: slot.displayID)
        }
    }

    /// Tell every page which moment of its day to be at.
    ///
    /// The Lock Screen can only play a looping video, and the extension restarts it on each lock (the
    /// freeze workaround) — so the clip always begins at its first frame while the desktop follows the
    /// wall clock. Calling this just after unlock puts the desktop at the same phase the clip is at, so
    /// the two show the same sky instead of the same scene a few hours apart.
    func setPhase(seconds: Double, attempt: Int = 1) {
        var applied = 0
        for slot in slots {
            guard let web = slot.web else { continue }
            applied += 1
            // A silent failure here is invisible: the phase simply stays at the wall clock and the two
            // surfaces disagree, so report both the error and what the page says afterwards.
            web.evaluateJavaScript("window.__lwSetPhase && window.__lwSetPhase(\(seconds))") { _, error in
                if let error {
                    NSLog("LIVEWALLPAPER setPhase(\(seconds)) FAILED on \(slot.displayID): "
                          + error.localizedDescription)
                }
            }
            web.evaluateJavaScript("(typeof window.__lwTitleInfo === 'function') ? window.__lwTitleInfo() : 'no-report'") {
                value, error in
                let text = (value as? String) ?? "nil"
                NSLog("LIVEWALLPAPER setPhase(\(seconds)) -> display \(slot.displayID): \(text.prefix(150))"
                      + (error.map { " [\($0.localizedDescription)]" } ?? ""))
            }
        }
        // A phase asked for before the pages finished loading would otherwise be lost (the request only
        // exists in the page's memory), so retry a few times while the pages settle.
        if applied == 0 && attempt <= 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.setPhase(seconds: seconds, attempt: attempt + 1)
            }
        }
    }
    private var players: [AVQueuePlayer] = []       // one per distinct video wallpaper
    private var loopers: [AVPlayerLooper] = []      // AVPlayerLooper deallocates if not retained
    private var syncTimer: Timer?
    private(set) var paused = false

    /// Shared clock for animation phase — every page is aligned to this epoch.
    private(set) var epoch: Double = Date().timeIntervalSince1970 * 1000

    /// kCGDesktopIconWindow - 1: above the wallpaper picture, below the icons and every normal window.
    static let level = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1

    /// Number of video decoders alive — one per distinct video wallpaper, not one per screen.
    var playerCount: Int { players.count }

    var onChange: (() -> Void)?
    var onGeometryMismatch: (() -> Void)?
    /// The self-test turns this off while it deliberately resizes a window.
    var geometryHealing = true

    // MARK: display helpers

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return 0
    }

    static func describe(_ screen: NSScreen) -> String {
        "\(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height)) " +
        "@\(String(format: "%.0f", screen.backingScaleFactor))x"
    }

    // MARK: show / teardown

    /// `plan` has one entry per display; entries may use different wallpapers.
    /// New windows are created before the old ones are retired, so the desktop picture is never
    /// exposed in between (that gap is what looks like the wallpaper "flashing back to the Mac one").
    func show(_ plan: [(screen: NSScreen, wallpaper: Wallpaper)]) {
        // (windows are laid out below; occlusion is re-checked right after)
        let retiredSlots = slots
        let retiredPlayers = players
        let retiredLoopers = loopers
        slots = []
        players = []
        loopers = []

        paused = false

        // Video: ONE player per distinct video wallpaper, one layer per screen — identical frames on
        // every display by construction, and only one decode.
        var playerFor: [String: AVQueuePlayer] = [:]

        for entry in plan {
            var player: AVQueuePlayer?
            if entry.wallpaper.kind == .video {
                if let existing = playerFor[entry.wallpaper.name] {
                    player = existing
                } else {
                    let p = AVQueuePlayer()
                    let looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: entry.wallpaper.renderURL))
                    p.isMuted = true
                    p.play()
                    players.append(p)
                    loopers.append(looper)
                    playerFor[entry.wallpaper.name] = p
                    player = p
                }
            }
            slots.append(makeSlot(screen: entry.screen, wallpaper: entry.wallpaper, player: player))
        }

        for slot in slots { slot.window.orderFront(nil) }

        // now the old layer can go away — the new one already covers every display
        for slot in retiredSlots {
            slot.window.orderOut(nil)
            slot.window.contentView = nil
        }
        for p in retiredPlayers { p.pause() }
        _ = retiredLoopers

        startSyncTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.checkGeometry() }
        onChange?()
    }

    func setPaused(_ pause: Bool) {
        guard pause != paused else { return }
        paused = pause
        if pause {
            syncTimer?.invalidate(); syncTimer = nil
            for p in players { p.pause() }
            for slot in slots { slot.window.orderOut(nil) }
        } else {
            for p in players { p.play() }
            for slot in slots { slot.window.orderFront(nil) }
            syncNow()
            startSyncTimer()
        }
        onChange?()
    }

    private func makeSlot(screen: NSScreen, wallpaper: Wallpaper, player: AVQueuePlayer?) -> ScreenSlot {
        let frame = screen.frame
        let window = WallpaperWindow(contentRect: frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Self.level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true          // click-through
        window.hasShadow = false
        window.isOpaque = true
        // scene colour, not black: while a page loads/reloads the window keeps painting this instead
        // of flashing white (WebKit's default) or letting the desktop show through
        window.backgroundColor = NSColor(calibratedRed: 0.016, green: 0.024, blue: 0.051, alpha: 1)
        window.isReleasedWhenClosed = false

        var slot = ScreenSlot(screen: screen, displayID: Self.displayID(of: screen), window: window,
                              wallpaper: wallpaper, web: nil, videoLayer: nil)

        if let player {
            let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.cgColor
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill          // fills any resolution / aspect ratio
            layer.frame = container.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            container.layer?.addSublayer(layer)
            window.contentView = container
            slot.videoLayer = layer
        } else {
            let view = SlotWebView(frame: CGRect(origin: .zero, size: frame.size),
                                   configuration: WKWebViewConfiguration())
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = view          // without this onReady never fires
            // transparent page background: the window's scene colour shows during load/first paint
            if view.responds(to: NSSelectorFromString("setDrawsBackground:")) {
                view.setValue(false, forKey: "drawsBackground")
            }
            view.onReady = { [weak self, weak view] in
                guard let self, let view else { return }
                self.injectHostScript(into: view)
                self.syncNow()
            }
            // A regenerated wallpaper keeps its path, so WebKit would serve the previous HTML from its
            // cache — which makes an updated page (new JS hooks, a different scene) look like it had no
            // effect. loadFileURL is kept because it is what grants read access to the assets folder.
            URLCache.shared.removeAllCachedResponses()
            view.loadFileURL(wallpaper.renderURL,
                             allowingReadAccessTo: wallpaper.renderURL.deletingLastPathComponent())
            window.contentView = view
            slot.web = view
        }
        return slot
    }

    func teardown() {
        syncTimer?.invalidate()
        syncTimer = nil
        for p in players { p.pause() }
        players.removeAll()
        loopers.removeAll()
        for slot in slots {
            slot.window.orderOut(nil)
            slot.window.contentView = nil
        }
        slots.removeAll()
    }

    // MARK: animation sync

    private func startSyncTimer() {
        syncTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.syncNow() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    /// Push the shared clock into every page, in the same run-loop turn, so all screens show the
    /// same animation phase. Returns the number of pages that accepted it.
    @discardableResult
    func syncNow() -> Int {
        let t = Date().timeIntervalSince1970 * 1000 - epoch
        var targets = 0
        for slot in slots {
            guard let web = slot.web else { continue }
            targets += 1
            web.evaluateJavaScript("window.__lwSetEpoch && window.__lwSetEpoch(\(String(format: "%.0f", epoch)))") { _, _ in }
            web.evaluateJavaScript("window.__lwAlignAt && window.__lwAlignAt(\(t))") { _, _ in }
        }
        return targets
    }

    /// A first pass can land on a stale display arrangement (the window server hands a fresh process
    /// the previous layout). Compare against fresh screens and correct in place; if it still does not
    /// fit, ask the delegate to rebuild from scratch.
    func checkGeometry(attempt: Int = 0) {
        guard geometryHealing else { return }
        let fresh = NSScreen.screens
        var mismatched = 0
        for slot in slots {
            guard let screen = fresh.first(where: { Self.displayID(of: $0) == slot.displayID }) else { continue }
            let s = screen.frame, w = slot.window.frame
            if abs(s.minX - w.minX) > 1 || abs(s.minY - w.minY) > 1
                || abs(s.width - w.width) > 1 || abs(s.height - w.height) > 1 {
                mismatched += 1
                slot.window.setFrame(s, display: true)
            }
        }
        guard mismatched > 0 else { return }
        NSLog("LIVEWALLPAPER corrected \(mismatched) window frame(s), attempt \(attempt)")
        if attempt < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.checkGeometry(attempt: attempt + 1) }
        } else {
            onGeometryMismatch?()
        }
    }

    /// Injected after load: publishes the screen geometry as CSS variables (so any wallpaper can
    /// adapt to the display it landed on), installs the probe entry point, and drives every CSS
    /// animation from the shared wall clock so no single WebKit view can drift out of phase.
    private func injectHostScript(into view: WKWebView) {
        let script = Self.hostScript.replacingOccurrences(of: "__LW_EPOCH__",
                                                          with: String(format: "%.0f", epoch))
        view.evaluateJavaScript(script) { _, error in
            if let error { NSLog("LIVEWALLPAPER inject failed: \(error.localizedDescription)") }
        }
    }

    static let hostScript = #"""
    (function () {
      var root = document.documentElement;
      window.__lwEpoch = __LW_EPOCH__;

      function publishGeometry() {
        root.style.setProperty('--screen-width', window.innerWidth + 'px');
        root.style.setProperty('--screen-height', window.innerHeight + 'px');
        root.style.setProperty('--screen-scale', String(window.devicePixelRatio));
        root.style.setProperty('--screen-aspect', window.innerWidth + ' / ' + window.innerHeight);
      }
      publishGeometry();
      window.addEventListener('resize', publishGeometry);

      function align(t) {
        if (!document.getAnimations) { return 0; }
        var list = document.getAnimations(), aligned = 0;
        for (var i = 0; i < list.length; i++) {
          var animation = list[i], duration = 0;
          try { duration = animation.effect.getTiming().duration; } catch (e) { duration = 0; }
          if (!duration || duration === Infinity) { continue; }
          animation.currentTime = ((t % duration) + duration) % duration;
          aligned++;
        }
        return aligned;
      }
      window.__lwAlignAt = align;
      window.__lwSetEpoch = function (e) { window.__lwEpoch = e; };

      // Drive from Date.now() rather than letting each page run its own timeline: that is what keeps
      // three displays showing the same phase even when WebKit throttles one of the views.
      function tick() {
        align(Date.now() - window.__lwEpoch);
        window.requestAnimationFrame(tick);
      }
      if (window.requestAnimationFrame && document.getAnimations) { window.requestAnimationFrame(tick); }

      // Everything the test harness wants to know about this page.
      window.__lwInfo = function () {
        var list = document.getAnimations ? document.getAnimations() : [];
        var times = [];
        for (var i = 0; i < list.length; i++) {
          var value = list[i].currentTime;
          times.push(value === null ? -1 : Math.round(value));
        }
        var out = {
          url: location.pathname,
          title: document.title,
          w: window.innerWidth,
          h: window.innerHeight,
          dpr: window.devicePixelRatio,
          anim: times,
          epoch: window.__lwEpoch,
          // the wallpaper's own report, when it has one (the Starbound page exposes __lwTitleInfo):
          // without this the host probe says nothing about what the page actually drew or which phase it
          // thinks it is at, which is exactly what a phase-alignment bug hides behind
          page: (typeof window.__lwTitleInfo === 'function') ? window.__lwTitleInfo() : null
        };
        // a canvas wallpaper may publish its own animation state (e.g. the Starbound title screen)
        try {
          if (window.__lwTitleInfo) {
            var extra = JSON.parse(window.__lwTitleInfo());
            for (var k in extra) { out['lw_' + k] = extra[k]; }
          }
        } catch (e) {}
        return JSON.stringify(out);
      };
    })();
    """#

    // MARK: reporting

    func statusLines() -> [String] {
        slots.map { slot in
            let frame = NSStringFromRect(slot.window.frame)
            let scale = String(format: "%.0f", slot.screen.backingScaleFactor)
            let content = slot.web != nil ? "web" : "video"
            return "display=\(slot.displayID) \(slot.screen.localizedName) frame=\(frame) @\(scale)x " +
                   "wallpaper=\(slot.wallpaper.name) kind=\(slot.wallpaper.kind.rawValue)/\(content) " +
                   "visible=\(slot.window.isVisible) level=\(slot.window.level.rawValue)"
        }
    }

    /// Per-slot JSON from the page, plus the video clock. Used by --status and the self-test.
    func probe(_ completion: @escaping ([(display: CGDirectDisplayID, label: String, info: String)]) -> Void) {
        var out: [(CGDirectDisplayID, String, String)] = []
        let group = DispatchGroup()
        for slot in slots {
            group.enter()
            let label = "\(slot.displayID) \(slot.screen.localizedName)"
            if let web = slot.web {
                web.evaluateJavaScript("window.__lwInfo && window.__lwInfo()") { value, _ in
                    out.append((slot.displayID, label, (value as? String) ?? "no-info"))
                    group.leave()
                }
            } else if let layer = slot.videoLayer, let player = layer.player {
                let t = player.currentTime().seconds
                out.append((slot.displayID, label,
                            "{\"video\":true,\"t\":\(String(format: "%.2f", t)),\"rate\":\(player.rate)," +
                            "\"layer\":\"\(NSStringFromRect(layer.frame))\",\"url\":\"\(slot.wallpaper.renderURL.lastPathComponent)\"}"))
                group.leave()
            } else {
                out.append((slot.displayID, label, "{\"empty\":true}"))
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(out) }
    }
}
