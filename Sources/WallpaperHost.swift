// WallpaperHost.swift — the engine: one borderless window per display, sitting one level below the
// desktop icons. Knows nothing about the UI.

import AppKit
import AVFoundation
import WebKit

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperHost {
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []      // one per screen
    private var loopers: [AVPlayerLooper] = []     // AVPlayerLooper deallocates if not retained
    private var webViews: [WKWebView] = []

    private(set) var current: Wallpaper?
    private(set) var paused = false

    /// kCGDesktopIconWindow - 1: above the wallpaper picture, below the icons and every normal window.
    static let level = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1

    var onChange: ((Wallpaper?, Bool) -> Void)?

    func show(_ wallpaper: Wallpaper) {
        teardown()
        current = wallpaper
        paused = false
        for screen in NSScreen.screens {
            windows.append(makeWindow(on: screen, wallpaper: wallpaper))
        }
        for w in windows { w.orderFront(nil) }
        onChange?(current, paused)
    }

    func setPaused(_ pause: Bool) {
        guard pause != paused else { return }
        paused = pause
        if pause {
            for p in players { p.pause() }
            for w in windows { w.orderOut(nil) }
        } else {
            for p in players { p.play() }
            for w in windows { w.orderFront(nil) }
        }
        onChange?(current, paused)
    }

    /// Recreate the windows — used after a display change and by the Reload menu item.
    func rebuild() {
        guard let wallpaper = current else { return }
        show(wallpaper)
    }

    private func makeWindow(on screen: NSScreen, wallpaper: Wallpaper) -> NSWindow {
        let w = WallpaperWindow(contentRect: screen.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Self.level)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true          // click-through
        w.hasShadow = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false

        if wallpaper.kind == .video {
            let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            let player = AVQueuePlayer()
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: wallpaper.renderURL))
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
        } else {
            let view = WKWebView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                 configuration: WKWebViewConfiguration())
            view.autoresizingMask = [.width, .height]
            view.loadFileURL(wallpaper.renderURL,
                             allowingReadAccessTo: wallpaper.renderURL.deletingLastPathComponent())
            webViews.append(view)
            w.contentView = view
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

    func statusLines() -> [String] {
        windows.map { "frame=\(NSStringFromRect($0.frame)) level=\($0.level.rawValue) visible=\($0.isVisible)" }
    }

    /// Ask each page what it actually rendered — proof the wallpaper loaded, not just a black window.
    func probeWeb(_ completion: @escaping ([String]) -> Void) {
        guard !webViews.isEmpty else { return completion([]) }
        let js = """
        (function(){
          const stars = document.getElementById('stars');
          window.__probe = 'pending';
          const i = new Image();
          i.onload  = () => { window.__probe = 'asset ' + i.naturalWidth + 'x' + i.naturalHeight; };
          i.onerror = () => { window.__probe = 'asset none'; };
          i.src = 'assets/sector_bg.png';
          return document.title + ' | layers=' + document.querySelectorAll('.layer').length
               + ' | anim=' + (stars ? getComputedStyle(stars).animationName : 'n/a')
               + ' | bodyH=' + (document.body ? document.body.offsetHeight : -1);
        })()
        """
        var out: [String] = []
        let group = DispatchGroup()
        for (n, view) in webViews.enumerated() {
            group.enter()
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
