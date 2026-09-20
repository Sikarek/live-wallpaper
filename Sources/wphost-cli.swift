// wphost.swift — a minimal macOS animated-wallpaper host, written from scratch.
//
// build:  swiftc -O -o wphost wphost.swift
// run:    ./wphost                          (built-in demo animation)
//         ./wphost --web  /path/index.html  (your HTML/canvas wallpaper)
//         ./wphost --video /path/loop.mp4   (your video loop)
//         add --seconds N to auto-quit (handy for testing)
//
// No Xcode project, no Apple Developer account, no notarization: it is signed
// ad-hoc by default and runs locally. Requires the Command Line Tools SDK only.

import AppKit
import QuartzCore
import AVFoundation
import WebKit

// One level BELOW kCGDesktopIconWindow: below the icons, above the wallpaper picture.
let DESKTOP_ICON = Int(CGWindowLevelForKey(.desktopIconWindow))
let OUR_LEVEL = DESKTOP_ICON - 1

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Host: NSObject, NSApplicationDelegate {
    enum Mode { case demo, web(URL), video(URL) }

    let mode: Mode
    var windows: [NSWindow] = []
    var players: [AVQueuePlayer] = []   // must be retained (one per screen)
    var loopers: [AVPlayerLooper] = []  // must be retained too

    init(mode: Mode) { self.mode = mode }

    func applicationDidFinishLaunching(_ note: Notification) {
        for screen in NSScreen.screens { windows.append(make(on: screen)) }
        NSLog("WPHOST levels: normal=\(Int(CGWindowLevelForKey(.normalWindow))) desktop=\(Int(CGWindowLevelForKey(.desktopWindow))) desktopIcon=\(DESKTOP_ICON) mine=\(OUR_LEVEL)")
        for w in windows {
            NSLog("WPHOST window frame=\(NSStringFromRect(w.frame)) level=\(w.level.rawValue) visible=\(w.isVisible) onActiveSpace=\(w.isOnActiveSpace)")
        }
    }

    func make(on screen: NSScreen) -> NSWindow {
        let w = WallpaperWindow(contentRect: screen.frame,
                                styleMask: [.borderless],
                                backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: OUR_LEVEL)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true          // click-through
        w.hasShadow = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false

        switch mode {
        case .demo:            w.contentView = demoView(size: screen.frame.size)
        case .web(let url):    w.contentView = webView(url, size: screen.frame.size)
        case .video(let url):  w.contentView = videoView(url, size: screen.frame.size, screen: screen)
        }
        w.orderFront(nil)
        return w
    }

    // ---- content: a slow animated gradient (proves the window is alive) ----
    func demoView(size: CGSize) -> NSView {
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = v.bounds
        g.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        g.colors = [NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.07, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.34, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.03, green: 0.20, blue: 0.24, alpha: 1).cgColor]
        g.startPoint = CGPoint(x: 0.0, y: 0.0)
        g.endPoint = CGPoint(x: 1.0, y: 1.0)
        let a = CABasicAnimation(keyPath: "startPoint")
        a.fromValue = CGPoint(x: 0.0, y: 0.0)
        a.toValue = CGPoint(x: 1.0, y: 1.0)
        a.duration = 18
        a.autoreverses = true
        a.repeatCount = .infinity
        g.add(a, forKey: "drift")
        v.layer?.addSublayer(g)
        return v
    }

    // ---- content: any local HTML/CSS/JS page (canvas included) ----
    func webView(_ url: URL, size: CGSize) -> NSView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return wv
    }

    // ---- content: looping, muted video (hardware decoded) ----
    func videoView(_ url: URL, size: CGSize, screen: NSScreen) -> NSView {
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        let p = AVQueuePlayer()
        let l = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspectFill
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
        p.isMuted = true
        p.play()
        players.append(p)
        loopers.append(l)
        let tag = "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(Int(screen.frame.minX))"
        NSLog("WPHOST video: \(url.lastPathComponent) screen=\(tag) playing=\(p.rate != 0)")
        for t in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSLog("WPHOST video screen=\(tag) t=\(String(format: "%.2f", p.currentTime().seconds))s itemStatus=\(p.currentItem?.status.rawValue ?? -1) rate=\(p.rate)")
            }
        }
        return v
    }
}

// ---------------- cli ----------------
var mode: Host.Mode = .demo
var seconds: Double = 0
let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--web"   where i + 1 < argv.count: mode = .web(URL(fileURLWithPath: argv[i + 1])); i += 2
    case "--video" where i + 1 < argv.count: mode = .video(URL(fileURLWithPath: argv[i + 1])); i += 2
    case "--seconds" where i + 1 < argv.count: seconds = Double(argv[i + 1]) ?? 0; i += 2
    default: i += 1
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // menu-bar style: no Dock icon, no focus stealing
let host = Host(mode: mode)
app.delegate = host
if seconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        NSLog("WPHOST quitting after \(seconds)s")
        NSApp.terminate(nil)
    }
}
app.run()
