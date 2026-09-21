// ComposerUI.swift — the window: knobs on the left, live preview on the right.

import SwiftUI

struct ComposerUI: View {
    @ObservedObject var composer: Composer

    private let labelWidth: CGFloat = 118

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            controls
                .frame(width: 390)
            preview
        }
        .padding(14)
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
            composer.refreshSavedList()
            composer.refreshSlotStatus()
            if composer.previewURL == nil { composer.refreshPreview() }
        }
        // Every knob change rebuilds the preview (coalesced, so dragging a slider costs one build).
        .onChange(of: composer.signature) { _, _ in composer.schedulePreview() }
    }

    // MARK: - left column

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !composer.toolsOK {
                    GroupBox {
                        Text("The backdrop tools were not found. Run ./build.sh so they get bundled, or keep the "
                             + "repo at ~/Projects/live-wallpaper.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
                savedBox
                planetBox
                skyBox
                bodiesBox
                exportBox
                lockScreenBox
            }
            .padding(.bottom, 8)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: labelWidth, alignment: .trailing)
                .foregroundStyle(.secondary).font(.callout)
            content()
            Spacer(minLength: 0)
        }
    }

    private var savedBox: some View {
        GroupBox("Start from a saved wallpaper") {
            VStack(alignment: .leading, spacing: 6) {
                row("saved") {
                    Picker("", selection: $composer.savedWallpaper) {
                        ForEach(composer.savedList, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 190)
                    Button("Load") {
                        composer.load(from: Composer.libraryDir.appendingPathComponent(composer.savedWallpaper))
                    }.disabled(composer.savedWallpaper.isEmpty)
                    Button("↻") { composer.refreshSavedList() }.help("rescan the library")
                }
                Text("Loads a combination you already exported (every knob comes back from its "
                     + "backdrop.json), so you can branch off it and export a copy.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var lockScreenBox: some View {
        GroupBox("Lock Screen") {
            VStack(alignment: .leading, spacing: 6) {
                Text(composer.slotStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Render & Install for the Lock Screen") {
                        composer.renderForLockScreen { composer.refreshSlotStatus() }
                    }
                    .disabled(composer.busy)
                    if composer.busy { ProgressView().controlSize(.small) }
                    Button("↻") { composer.refreshSlotStatus() }.help("re-read the slot")
                }
                Text("The Lock Screen can only play a video, so the combination has to be rendered to one "
                     + "and installed into Apple's aerial slot. Same plan file, same day length, so the two "
                     + "sides stay in step. 4K at the wallpaper's day length: minutes, not seconds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var planetBox: some View {
        GroupBox("Planet") {
            VStack(alignment: .leading, spacing: 6) {
                row("biome") {
                    Picker("", selection: $composer.planet) {
                        ForEach(composer.planetChoices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 160)
                }
                row("surface liquid") {
                    Picker("", selection: $composer.liquid) {
                        ForEach(composer.liquidChoices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 160)
                }
                Text("biome = the land, the liquid fills the gaps between the masks. gas giants are in "
                     + "“parent planet” — the game has no horizon art for them, so they only ever appear in the sky.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                row("masks") {
                    ForEach(0..<3, id: \.self) { i in
                        Picker("", selection: Binding(
                            get: { composer.masks.indices.contains(i) ? composer.masks[i] : 0 },
                            set: { new in
                                var m = composer.masks
                                while m.count < 3 { m.append(0) }
                                m[i] = new
                                composer.masks = m
                            })) {
                            Text("none").tag(0)
                            ForEach(composer.palette?.masks ?? [], id: \.self) { Text("\($0)").tag($0) }
                        }.labelsHidden().frame(width: 58)
                    }
                    Button("random") { composer.randomMasks() }
                        .fixedSize()
                        .help("re-roll the masks for this biome (the count follows the biome's own rule)")
                }
                if composer.liquid == "none" {
                    row("mask strength") {
                        Slider(value: $composer.maskAlpha, in: 0...0.6)
                        Text(String(format: "%.2f", composer.maskAlpha)).monospacedDigit().frame(width: 40)
                    }
                } else {
                    Text("With a surface liquid the mask numbers ARE the landmasses: land where they cover, "
                         + "liquid in the gaps. Pick different (or fewer) masks to change how much sea the "
                         + "world has — “mask strength” only applies to dry worlds.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                row("hue shift") {
                    Slider(value: $composer.hueShift, in: -180...180)
                    Text("\(Int(composer.hueShift))°").monospacedDigit().frame(width: 44)
                }
            }
            .padding(.top, 2)
        }
    }

    private var skyBox: some View {
        GroupBox("Sky") {
            VStack(alignment: .leading, spacing: 6) {
                row("clouds") {
                    Slider(value: $composer.cloudAlpha, in: 0...6)
                    Text(String(format: "%.1f", composer.cloudAlpha)).monospacedDigit().frame(width: 34)
                }
                row("redraw rate") {
                    Picker("", selection: $composer.fps) {
                        Text("15").tag(15); Text("20").tag(20); Text("24").tag(24)
                        Text("30").tag(30); Text("60").tag(60); Text("uncapped").tag(0)
                    }.labelsHidden().frame(width: 110)
                    Text("fps (the sky's clock runs regardless)").font(.caption).foregroundStyle(.secondary)
                }
                row("stars / cell") {
                    Slider(value: Binding(get: { Double(composer.starsPerCell) },
                                          set: { composer.starsPerCell = Int($0) }), in: 20...160)
                    Text("\(composer.starsPerCell)").monospacedDigit().frame(width: 34)
                }
                row("day length") {
                    Slider(value: $composer.dayLength, in: 120...1800, step: 10)
                    Text("\(Int(composer.dayLength)) s").monospacedDigit().frame(width: 58)
                }
                Text("A day is one full turn of the sky. 600 s is the game's default; the Lock Screen video "
                     + "uses the same number, so keep them equal if you want the two to match.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var bodiesBox: some View {
        GroupBox("Moons & planet in the sky") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(composer.bodies.enumerated()), id: \.element.id) { index, _ in
                    bodyEditor(index)
                }
                HStack(spacing: 8) {
                    Button("＋ moon") {
                        var body = Composer.Body()
                        body.type = composer.planetChoices.first ?? "moon"
                        body.seed = Int.random(in: 1...9_999_999)
                        composer.bodies.append(body)
                        composer.schedulePreview()
                    }
                    .disabled(composer.bodies.filter { !$0.isParent }.count >= 3)
                    Button("＋ parent planet") {
                        var body = Composer.Body()
                        body.type = "gasgiant"
                        body.isParent = true
                        body.seed = Int.random(in: 1...9_999_999)
                        composer.bodies.append(body)
                        composer.schedulePreview()
                    }
                    .disabled(composer.bodies.contains { $0.isParent })
                    Spacer()
                }
                Text("Every value the engine derives for a body is here: size, hue, which shadow sprite, "
                     + "where it sits, and a seed that re-rolls its continents. gasgiant is sky-only (the "
                     + "game has no horizon art for them). -1 / 0 means \u{201C}take it from the world seed\u{201D}.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func bodyEditor(_ index: Int) -> some View {
        let body = composer.bodies[index]
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                row("size") {
                    Slider(value: bindingFor(index, \.size), in: 0.3...2.5)
                    Text(String(format: "%.1fx", body.size)).monospacedDigit().frame(width: 44)
                }
                row("hue") {
                    Slider(value: bindingFor(index, \.hue), in: -1...359)
                    Text(body.hue < 0 ? "seed" : "\(Int(body.hue))°").monospacedDigit().frame(width: 48)
                }
                row("shadow") {
                    Picker("", selection: bindingFor(index, \.shadow)) {
                        Text("seed").tag(0)
                        ForEach(composer.palette?.shadows ?? [], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: 110)
                    Text("1 and 7 are the lit ones").font(.caption).foregroundStyle(.secondary)
                }
                row("position") {
                    Slider(value: bindingFor(index, \.x), in: -1...1)
                    Text(body.x < 0 ? "seed" : String(format: "x %.2f", body.x)).monospacedDigit()
                        .frame(width: 60)
                }
                row("") {
                    Slider(value: bindingFor(index, \.y), in: -1...1)
                    Text(body.y < 0 ? "seed" : String(format: "y %.2f", body.y)).monospacedDigit()
                        .frame(width: 60)
                }
                row("continents") {
                    Button("re-roll") {
                        composer.bodies[index].seed = Int.random(in: 1...9_999_999)
                        composer.schedulePreview()
                    }
                    Text(body.seed > 0 ? "seed \(body.seed)" : "from the world seed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Picker("", selection: bindingFor(index, \.type)) {
                    ForEach(composer.worldChoices.filter { $0 != "none" }, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 130)
                Text(body.isParent ? "planet you orbit" : "moon")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("✕") {
                    composer.bodies.remove(at: index)
                    if composer.bodies.isEmpty { composer.bodies = [Composer.Body()] }
                    composer.schedulePreview()
                }.buttonStyle(.borderless)
            }
        }
    }

    /// A binding into one field, so the Sliders and Pickers can stay declarative.
    private func bindingFor<Value>(_ index: Int, _ path: WritableKeyPath<Composer.Body, Value>) -> Binding<Value> {
        Binding(
            get: { composer.bodies.indices.contains(index) ? composer.bodies[index][keyPath: path]
                                                           : Composer.Body()[keyPath: path] },
            set: { newValue in
                guard composer.bodies.indices.contains(index) else { return }
                composer.bodies[index][keyPath: path] = newValue
                composer.schedulePreview()
            })
    }

    private var exportBox: some View {
        GroupBox("Save it") {
            VStack(alignment: .leading, spacing: 8) {
                row("name") {
                    TextField("starbound-custom", text: $composer.name)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                row("seed") {
                    TextField("1234567", value: $composer.seed, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 110)
                    Button("new") { composer.seed = Int.random(in: 1...9_999_999); composer.refreshPreview() }
                }
                HStack(spacing: 8) {
                    Button("Randomise") { composer.randomize() }
                    Button("Reset") { composer.resetToDefault() }
                    Spacer()
                    Button("Export") { composer.export(useNow: false) }
                        .keyboardShortcut("e", modifiers: [.command])
                    Button("Export & Use Now") { composer.export(useNow: true) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                }
                Text("Export writes a wallpaper folder into the LiveWallpaper library and tells the app to "
                     + "reload. “Use Now” also puts it on every display.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - right column

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewPane(composer: composer)
                .frame(minWidth: 620, minHeight: 470)      // a GeometryReader has no ideal size of its own
            HStack(spacing: 10) {
                if composer.busy { ProgressView().controlSize(.small) }
                Text(composer.status).font(.callout).lineLimit(1)
                Spacer()
                Text(probeSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// A one-line read-out of what the page reported — proof the preview is really rendering.
    private var probeSummary: String {
        guard let data = composer.probe.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return composer.probe.isEmpty ? "" : composer.probe
        }
        let stars = json["starsDrawn"] as? Int ?? 0
        let clouds = json["cloudsDrawn"] as? Int ?? 0
        let orbiters = json["orbitersDrawn"] as? Int ?? 0
        let fps = json["fps"] as? Int ?? 0
        return "stars \(stars) · clouds \(clouds) · bodies \(orbiters) · \(fps) fps"
    }
}
