import SwiftUI

struct GameDetailsSheet: View {
    let content: GamePanelContent
    let compat: CompatibilityModel
    @Bindable var model: LibraryModel
    var height: CGFloat = 620

    @Environment(\.dismiss) private var dismiss
    @State private var chip: String?

    private var thisMac: String? { compat.chip }

    private var chips: [String] {
        let gpu = compat.data?.gpuStrength ?? [:]
        return gpu.keys.sorted { (gpu[$0]!, $0) < (gpu[$1]!, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.game.name).font(.system(size: 17, weight: .bold)).padding([.horizontal, .top], 20)
            Form {
                ForEach(content.detailsSections, id: \.self) { section in
                    block(section)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: height)
        .onAppear { chip = chip ?? thisMac }
    }

    @ViewBuilder
    private func block(_ section: GamePanelContent.DetailsSection) -> some View {
        switch section {
        case .expected:
            Section(section.title) {
                let result = CompatEstimate.compute(reports: content.compat.mac?.reports ?? [], method: .wine,
                                                    chip: chip ?? thisMac, gpu: compat.data?.gpuStrength ?? [:])
                let (estimate, line) = GamePanelContent.estimate(result, macReportsOn: content.compat.macReportsOn)
                if let estimate {
                    EstimateRow(estimate: estimate)
                    Text(estimate.note).foregroundStyle(.secondary)
                } else if let line {
                    Text(line).foregroundStyle(.secondary)
                }
            }
        case .macPicker:
            Section {
                Picker(section.title, selection: Binding(get: { chip ?? thisMac ?? "" }, set: { chip = $0 })) {
                    if chips.isEmpty { Text("Unknown").tag("") }
                    ForEach(chips, id: \.self) { name in
                        Text(name == thisMac ? String(localized: "\(name) (this Mac)") : name).tag(name)
                    }
                }
                .disabled(chips.isEmpty)
            }
        case .allReports:
            Section(section.title) {
                if let rating = content.compat.mac?.rating {
                    LabeledContent(rating.label, value: GamePanelContent.reportCount(content.compat.mac?.reviewCount ?? 0))
                }
                ForEach(content.layers) { LayerRow(layer: $0, isBest: $0.layer == content.bestLayer) }
            }
        case .appleGamingWiki:
            Section(section.title) {
                ForEach(GamePanelContent.wikiRows(content.compat.wiki?.ratings ?? [:]), id: \.0) { method, rating in
                    LabeledContent(method, value: rating)
                }
            }
        case .antiCheat:
            if let summary = content.compat.antiCheat {
                Section(section.title) {
                    Text(summary.title)
                    ForEach(summary.details, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        case .advanced:
            Section(section.title) {
                AdvancedGameRows(game: content.game, model: model)
            }
        case .sources:
            Section {
                Text(content.compat.sourcesLine ?? CompatibilityCredits.sourcesLine(compat.data))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
