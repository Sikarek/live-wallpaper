// main.swift — Starbound Composer: app entry, window, menu.
//
//   StarboundComposer.app                    the window (knobs left, live preview right)
//   StarboundComposer.app ... --self-test    headless checks (see ComposerSelfTest.swift)

import AppKit
import SwiftUI

final class ComposerAppDelegate: NSObject, NSApplicationDelegate {

    let composer = Composer()
    private var window: NSWindow?

    /// Built for both a normal run and the `--dump-a11y` self check, so the dump inspects the real thing.
    @discardableResult
    func buildWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: ComposerUI(composer: composer))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Starbound Composer — celestial backdrop"
        window.contentView = hosting
        window.setFrameAutosaveName("ComposerWindow")
        // SwiftUI sizes a window to the content's *ideal* size, and a GeometryReader-driven preview pane
        // has none — so the window would open as a narrow strip. Set the content size explicitly.
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.center()
        return window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = buildWindow()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window, !window.isVisible { window.makeKeyAndOrderFront(nil) }
        return true
    }

    /// A minimal main menu: ⌘Q has to work, and the name/seed fields need an Edit menu to paste into.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Starbound Composer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Starbound Composer",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Starbound Composer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

let arguments = CommandLine.arguments
let app = NSApplication.shared

if arguments.contains("--probe") {
    // debug: load a generated folder in WebKit and print the page's own report
    let delegate = RawProbeDelegate(arguments: arguments)
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
} else if arguments.contains("--export") {
    // debug/scripting: run the window's own export path headlessly
    let delegate = ExportDelegate(arguments: arguments)
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
} else if arguments.contains("--slot-status") {
    // debug: what does the app see in the Lock Screen slot right now?
    let composer = Composer()
    print(composer.lockScreenStatus())
    exit(0)
} else if arguments.contains("--dump-a11y") {
    // debug: build the real window and print every control (no screenshot permission needed)
    let delegate = DumpA11yDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else if arguments.contains("--self-test") {
    let delegate = SelfTestDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)          // headless: no window, no Dock icon
    app.run()
} else {
    let delegate = ComposerAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
