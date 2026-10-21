import SwiftUI

struct AdvancedGameRows: View {
    let game: Game
    @Bindable var model: LibraryModel
    @State private var expanded = false

    private var supported: Set<AdvancedOption> {
        let setup = model.resolution(for: game).setup
        guard setup.version == .windows else { return [] }
        return AdvancedSupport.options(runner: setup.runner, backend: setup.backend,
                                       translation: setup.translation, availability: model.backendAvailability)
    }

    var body: some View {
        if !supported.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if supported.contains(.dlss) {
                        option("DLSS → MetalFX", note: "Enable DLSS in the game too.", key: \.dlss)
                    }
                    if supported.contains(.spatial) {
                        option("MetalFX upscaling", note: "Scales the game’s output, not in-game DLSS.", key: \.spatial)
                        if model.setup(for: game.id).advanced?.spatial == true {
                            HStack {
                                Text("Scale")
                                Slider(value: Binding(get: { model.setup(for: game.id).advanced?.spatialFactor ?? 2 }, set: { value in
                                    update { $0.spatialFactor = value }
                                }), in: 1...2, step: 0.1)
                                .accessibilityLabel(Text("MetalFX scale factor"))
                                Text((model.setup(for: game.id).advanced?.spatialFactor ?? 2).formatted(.number.precision(.fractionLength(1))) + "×")
                                    .monospacedDigit().foregroundStyle(Glass.label2)
                            }
                        }
                    }
                    if supported.contains(.advertiseAVX) {
                        option("AVX2 to Rosetta", note: "Advertises AVX support. Does not make games faster.", key: \.advertiseAVX)
                    }
                    if supported.contains(.msync) { option("MSync", note: nil, key: \.msync) }
                    if supported.contains(.highResolution) {
                        option("High Resolution", note: "Use the display’s full pixel density.", key: \.highResolution)
                    }
                    if supported.contains(.metalHUD) {
                        Toggle("Metal HUD", isOn: Binding(get: { model.setup(for: game.id).metalHUD ?? false }, set: { value in
                            var setup = model.setup(for: game.id); setup.metalHUD = value; model.setSetup(setup, for: game.id)
                        }))
                        .accessibilityLabel(Text("Metal Performance HUD"))
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
                .padding(12).groupBackground().padding(.top, 6)
                Text("Takes effect next launch. MSync and High Resolution affect this Windows folder.")
                    .font(.system(size: 11)).foregroundStyle(Glass.label2).padding(.top, 6)
            } label: {
                Text("Advanced").groupHeader()
            }
            .padding(.bottom, 18)
        }
    }

    private func update(_ change: (inout AdvancedGameOptions) -> Void) {
        var setup = model.setup(for: game.id)
        var options = setup.advanced ?? AdvancedGameOptions()
        change(&options)
        setup.advanced = options
        model.setSetup(setup, for: game.id)
    }

    private func option(_ title: LocalizedStringKey, note: LocalizedStringKey?, key: WritableKeyPath<AdvancedGameOptions, Bool>) -> some View {
        Toggle(isOn: Binding(get: { (model.setup(for: game.id).advanced ?? AdvancedGameOptions())[keyPath: key] }, set: { value in
            update { $0[keyPath: key] = value }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Glass.label2) }
            }
        }
    }
}
