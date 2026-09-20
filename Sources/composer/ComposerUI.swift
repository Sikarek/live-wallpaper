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
        .onAppear { if composer.previewURL == nil { composer.refreshPreview() } }
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
                planetBox
                skyBox
                bodiesBox
                exportBox
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
                        }.labelsHidden().frame(width: 66)
                    }
                }
                row("mask strength") {
                    Slider(value: $composer.maskAlpha, in: 0...0.6)
                    Text(String(format: "%.2f", composer.maskAlpha)).monospacedDigit().frame(width: 40)
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
                row("stars / cell") {
                    Slider(value: Binding(get: { Double(composer.starsPerCell) },
                                          set: { composer.starsPerCell = Int($0) }), in: 20...160)
                    Text("\(composer.starsPerCell)").monospacedDigit().frame(width: 34)
                }
                row("day length") {
                    Slider(value: $composer.dayLength, in: 120...1800)
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
            VStack(alignment: .leading, spacing: 6) {
                row("moons") {
                    Stepper(value: $composer.moons, in: 0...3) { Text("\(composer.moons)") }
                        .frame(width: 120)
                }
                ForEach(0..<max(0, composer.moons), id: \.self) { i in
                    row("moon \(i + 1)") {
                        Picker("", selection: Binding(
                            get: { composer.moonTypes.indices.contains(i) ? composer.moonTypes[i] : "moon" },
                            set: { new in
                                var t = composer.moonTypes
                                while t.count <= i { t.append("moon") }
                                t[i] = new
                                composer.moonTypes = t
                            })) {
                            ForEach(composer.planetChoices, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 160)
                    }
                }
                row("parent planet") {
                    Picker("", selection: $composer.parentPlanet) {
                        ForEach(composer.worldChoices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 160)
                }
                row("moon size") {
                    Slider(value: $composer.moonSize, in: 0.3...2.5)
                    Text(String(format: "%.1fx", composer.moonSize)).monospacedDigit().frame(width: 44)
                }
                row("planet size") {
                    Slider(value: $composer.planetSize, in: 0.3...2.5)
                    Text(String(format: "%.1fx", composer.planetSize)).monospacedDigit().frame(width: 44)
                }
                row("disc shadow") {
                    Picker("", selection: $composer.discShadow) {
                        Text("from seed").tag(0)
                        ForEach(composer.palette?.shadows ?? [], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: 120)
                }
                Text("Sizes are multipliers on the engine's own scales (moons 1.5×, the planet you orbit 3.0×).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
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
