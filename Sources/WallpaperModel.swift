// WallpaperModel.swift — the data side: where wallpapers live, what they are, and the shared UI state.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - paths

let appSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
let wallpapersDir = appSupport.appendingPathComponent("wallpapers", isDirectory: true)
let wrapperCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/LiveWallpaper", isDirectory: true)

let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]

// MARK: - model

struct Wallpaper: Identifiable, Hashable {
    enum Kind: String {
        case html, video, image

        var label: String {
            switch self {
            case .html:  return "HTML / animation"
            case .video: return "video loop"
            case .image: return "image"
            }
        }
        var symbol: String {
            switch self {
            case .html:  return "chevron.left.forwardslash.chevron.right"
            case .video: return "film"
            case .image: return "photo"
            }
        }
    }

    let name: String
    let source: URL        // the file in the wallpapers folder (best-effort, for Reveal in Finder)
    let kind: Kind
    let renderURL: URL     // what the engine actually loads (images get a generated wrapper page)

    var id: String { name }
}

// MARK: - library

enum Library {

    /// A wallpaper is a folder (with index.html, or one media file) or a loose media file.
    static func scan() -> [Wallpaper] {
        let fm = FileManager.default
        try? fm.createDirectory(at: wallpapersDir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: wallpapersDir, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var found: [Wallpaper] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let w = fromFolder(entry) { found.append(w) }
            } else if let w = fromFile(entry, name: entry.deletingPathExtension().lastPathComponent) {
                found.append(w)
            }
        }
        return found
    }

    private static func fromFolder(_ dir: URL) -> Wallpaper? {
        let fm = FileManager.default
        let index = dir.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) {
            return Wallpaper(name: dir.lastPathComponent, source: index, kind: .html, renderURL: index)
        }
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for f in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let w = fromFile(f, name: dir.lastPathComponent) { return w }
        }
        return nil
    }

    private static func fromFile(_ file: URL, name: String) -> Wallpaper? {
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            return Wallpaper(name: name, source: file, kind: .html, renderURL: file)
        case let e where videoExtensions.contains(e):
            return Wallpaper(name: name, source: file, kind: .video, renderURL: file)
        case let e where imageExtensions.contains(e):
            return Wallpaper(name: name, source: file, kind: .image, renderURL: wrap(image: file))
        default:
            return nil
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

    /// Copy an arbitrary file/folder the user picked into the wallpapers folder.
    @discardableResult
    static func adopt(_ url: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: wallpapersDir, withIntermediateDirectories: true)
        let dest = wallpapersDir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { return dest }   // already there
        do {
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            NSLog("LIVEWALLPAPER could not add \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    static func remove(_ wallpaper: Wallpaper) {
        // delete the whole wallpaper (folder if it is one, otherwise the loose file)
        let target = wallpaper.source.deletingLastPathComponent() == wallpapersDir
            ? wallpaper.source
            : wallpaper.source.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: target)
    }
}

// MARK: - shared UI state

final class AppModel: ObservableObject {
    @Published var wallpapers: [Wallpaper] = []
    @Published var selectedName: String?
    @Published var currentName: String?
    @Published var paused = false
    @Published var launchAtLogin = false
    @Published var displayCount = NSScreen.screens.count
    @Published var status = ""

    // actions wired up by the app delegate
    var onApply: ((Wallpaper) -> Void)?
    var onPause: ((Bool) -> Void)?
    var onReload: (() -> Void)?
    var onLaunchAtLogin: ((Bool) -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: ((Wallpaper) -> Void)?
    var onAdd: ((URL) -> Void)?

    var selected: Wallpaper? { wallpapers.first { $0.name == selectedName } }

    func refresh(keepSelection: Bool = true) {
        let previous = selectedName
        wallpapers = Library.scan()
        if !keepSelection || previous == nil || !wallpapers.contains(where: { $0.name == previous }) {
            selectedName = currentName ?? wallpapers.first?.name
        }
    }

    /// Called whenever the engine changes what is on screen.
    func engineChanged(to name: String?, paused isPaused: Bool) {
        currentName = name
        paused = isPaused
        if selectedName == nil { selectedName = name }
    }
}

// MARK: - launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LIVEWALLPAPER login item error: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
