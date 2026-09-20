// UI.swift — the window: wallpaper list, live preview, and settings.

import AppKit
import AVFoundation
import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            VStack(spacing: 0) {
                preview
                Divider()
                settings
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wallpapers")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if model.wallpapers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing here yet.").font(.callout)
                    Text("Add an HTML page, a video, or an image — or run\npython3 tools/starbound_wallpaper.py")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                Spacer()
            } else {
                List(selection: $model.selectedName) {
                    ForEach(model.wallpapers) { wallpaper in
                        row(for: wallpaper)
                            .tag(wallpaper.name)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack(spacing: 6) {
                Button("Add…") { addWallpapers() }
                Button("Reveal") { model.onReveal?() }
                Spacer()
                Button {
                    if let w = model.selected { model.onRemove?(w) }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.selected == nil)
                .help("Delete the selected wallpaper from the wallpapers folder")
            }
            .padding(10)
        }
    }

    private func row(for wallpaper: Wallpaper) -> some View {
        HStack(spacing: 8) {
            Image(systemName: wallpaper.kind.symbol)
                .frame(width: 18)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(wallpaper.name)
                Text(wallpaper.kind.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if model.isOnScreen(wallpaper.name) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .help("Currently on your desktop")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: preview + apply

    private var preview: some View {
        VStack(spacing: 0) {
            PreviewView(wallpaper: model.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selected?.name ?? "No wallpaper selected")
                        .font(.callout)
                        .bold()
                    Text(model.selected?.kind.label ?? "—")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if model.isOnScreen(model.selected?.name ?? "") {
                    Label(model.paused ? "Paused" : "On your desktop",
                          systemImage: model.paused ? "pause.circle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(model.paused ? .orange : .green)
                }
                Button {
                    if let w = model.selected { model.onApply?(w) }
                } label: {
                    Text(model.syncDisplays ? "Use on all displays" : "Use on all displays (sync)")
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.selected == nil || (model.syncDisplays && model.selected?.name == model.currentName))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

            Toggle("Pause wallpaper (hide it without quitting)", isOn: Binding(
                get: { model.paused },
                set: { model.onPause?($0) }
            ))
            .toggleStyle(.switch)

            Toggle("Start at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.onLaunchAtLogin?($0) }
            ))
            .toggleStyle(.switch)

                HStack {
                    Toggle("Sync all displays", isOn: Binding(
                        get: { model.syncDisplays },
                        set: { model.onSyncDisplays?($0) }
                    ))
                    .toggleStyle(.switch)
                    Spacer()
                    Button("Reload") { model.onReload?() }
                }

                if model.syncDisplays {
                    Label("\(model.displayCount) display\(model.displayCount == 1 ? "" : "s") — same wallpaper, phase-locked",
                          systemImage: "display")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.displays) { display in
                        HStack(spacing: 8) {
                            Image(systemName: "display")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(display.label).font(.caption)
                                Text(display.resolution).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { model.assignedName(for: display.id) ?? model.currentName ?? "" },
                                set: { model.onAssign?(display.id, $0) }
                            )) {
                                ForEach(model.wallpapers) { wallpaper in
                                    Text(wallpaper.name).tag(wallpaper.name)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }
                }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(wallpapersDir.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open folder") { model.onReveal?() }
                    .font(.caption)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func addWallpapers() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose an HTML file, a video, an image, or a folder containing one"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls { model.onAdd?(url) }
        }
    }
}

/// Live preview: the real thing, rendered in a small WebKit view or video layer.
struct PreviewView: NSViewRepresentable {
    let wallpaper: Wallpaper?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let key = wallpaper.map { "\($0.name)|\($0.kind.rawValue)" }
        guard coordinator.key != key else { return }
        coordinator.key = key
        coordinator.stop()
        for subview in view.subviews { subview.removeFromSuperview() }
        guard let wallpaper else { return }

        if wallpaper.kind == .video {
            let player = AVQueuePlayer()
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: wallpaper.renderURL))
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            player.isMuted = true
            player.play()
            coordinator.player = player       // retained by the coordinator on purpose
            coordinator.looper = looper
        } else {
            let web = WKWebView(frame: view.bounds, configuration: WKWebViewConfiguration())
            web.autoresizingMask = [.width, .height]
            web.loadFileURL(wallpaper.renderURL,
                            allowingReadAccessTo: wallpaper.renderURL.deletingLastPathComponent())
            view.addSubview(web)
            coordinator.web = web
        }
    }

    final class Coordinator {
        var key: String?
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        weak var web: WKWebView?

        func stop() {
            player?.pause()
            player = nil
            looper = nil
            web?.stopLoading()
            web?.removeFromSuperview()
        }
    }
}
