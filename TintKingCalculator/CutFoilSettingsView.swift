import SwiftUI

/// Instellingenscherm voor de Snijfolie-calculator: rolbreedte, machinemarge,
/// de kostenparameters (opstartkosten, arbeidsprijs per m², minimumprijs per
/// sticker) en de complexiteitsfactoren (Eenvoudig/Gemiddeld/Complex).
/// Werkt op zowel Mac als mobiel. Op Mac gebruiken we bewust geen `Form` in
/// een sheet — dat leidde tot inconsistent afgeknipte tekst — maar een
/// ScrollView met GroupBox-kaarten, net als de rest van de Mac-app.
/// Alles wordt direct opgeslagen in de Prijslijst zodat het bewaard blijft en
/// later weer aan te passen is zonder dat er iets herbouwd hoeft te worden.
struct CutFoilSettingsView: View {
    @ObservedObject var priceListStore: PriceListStore
    var onDone: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var rollPreset: CutFoilRollPreset = .cm122
    @State private var customRollWidthCm: Double = 122
    @State private var marginCm: Double = 8
    @State private var startupCost: Double = 25
    @State private var laborPricePerM2: Double = 20.0
    @State private var minimumPricePerPiece: Double = 1.00
    @State private var simpleMultiplier: Double = 1.0
    @State private var mediumMultiplier: Double = 2.2
    @State private var complexMultiplier: Double = 3.2

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var rollWidthCm: Double { rollPreset.widthCm ?? customRollWidthCm }
    private var usableWidthCm: Double { max(rollWidthCm - marginCm, 0) }

    private var areaFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL"))
    }
    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    private func loadFromStore() {
        let storedWidth = priceListStore.cutFoilRollWidthCm
        if storedWidth == 60 {
            rollPreset = .cm60
        } else if storedWidth == 122 {
            rollPreset = .cm122
        } else {
            rollPreset = .custom
            customRollWidthCm = storedWidth
        }
        marginCm = priceListStore.cutFoilMarginCm
        startupCost = priceListStore.cutFoilStartupCost
        laborPricePerM2 = priceListStore.cutFoilLaborPricePerM2
        minimumPricePerPiece = priceListStore.cutFoilMinimumPricePerPiece
        simpleMultiplier = priceListStore.cutFoilSimpleMultiplier
        mediumMultiplier = priceListStore.cutFoilMediumMultiplier
        complexMultiplier = priceListStore.cutFoilComplexMultiplier
    }

    private func save() {
        priceListStore.updateCutFoilSettings(
            rollWidthCm: rollWidthCm,
            marginCm: marginCm,
            startupCost: startupCost,
            laborPricePerM2: laborPricePerM2,
            minimumPricePerPiece: minimumPricePerPiece,
            simpleMultiplier: simpleMultiplier,
            mediumMultiplier: mediumMultiplier,
            complexMultiplier: complexMultiplier
        )
    }

    /// Eén instellingenrij: label links, veld + eenheid rechts. Stapelt op
    /// smalle (iPhone) breedte zodat lange labels nooit worden afgeknipt.
    @ViewBuilder
    private func settingRow(_ label: String, value: Binding<Double>, suffix: String, width: CGFloat = 85, precision: ClosedRange<Int> = 0...2) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                HStack {
                    AppNumberField(placeholder: label, value: value, decimals: precision)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: width)
                    Text(suffix).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } else {
            HStack {
                Text(label)
                Spacer(minLength: 16)
                AppNumberField(placeholder: label, value: value, decimals: precision)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                Text(suffix).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Rolinstellingen") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Rolbreedte", selection: $rollPreset) {
                            ForEach(CutFoilRollPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if rollPreset == .custom {
                            settingRow("Breedte", value: $customRollWidthCm, suffix: "cm", precision: 0...1)
                        }

                        settingRow("Marge (machine)", value: $marginCm, suffix: "cm", precision: 0...1)

                        Divider()

                        HStack {
                            Text("Bruikbare breedte").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(usableWidthCm.formatted(areaFormat)) cm").fontWeight(.semibold)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Kosten") {
                    VStack(alignment: .leading, spacing: 16) {
                        settingRow("Opstartkosten per opdracht", value: $startupCost, suffix: "€")

                        VStack(alignment: .leading, spacing: 6) {
                            settingRow("Arbeidsprijs per m² (Eenvoudig)", value: $laborPricePerM2, suffix: "€")
                            Text("Schaalt mee met de afmeting van elke sticker (bijv. €16,67/m² ≈ €0,50 voor 10×30 cm, €1,00 voor 10×60 cm) en bij Gemiddeld/Complex met de factoren hieronder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            settingRow("Minimumprijs per sticker", value: $minimumPricePerPiece, suffix: "€")
                            Text("Een sticker kost nooit minder dan dit bedrag, ook als materiaal + arbeid samen lager uitkomen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Complexiteitsfactoren") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Vermenigvuldigen de arbeidsprijs hierboven. Eenvoudig staat standaard op 1,0 (geen opslag); Gemiddeld en Complex verhogen de arbeidskosten naar verhouding.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        settingRow("Eenvoudig", value: $simpleMultiplier, suffix: "×", width: 65, precision: 1...2)
                        settingRow("Gemiddeld", value: $mediumMultiplier, suffix: "×", width: 65, precision: 1...2)
                        settingRow("Complex", value: $complexMultiplier, suffix: "×", width: 65, precision: 1...2)
                    }
                    .padding(.top, 6)
                }

                Text("Deze instellingen worden bewaard en gebruikt voor elke nieuwe berekening bij Snijfolie. Je kunt ze hier altijd weer aanpassen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(minWidth: isCompact ? 0 : 460, idealWidth: isCompact ? 0 : 520, minHeight: isCompact ? 0 : 560)
        .navigationTitle("Snijfolie-instellingen")
        .onAppear { loadFromStore() }
        .onChange(of: rollPreset) { _, _ in save() }
        .onChange(of: customRollWidthCm) { _, _ in save() }
        .onChange(of: marginCm) { _, _ in save() }
        .onChange(of: startupCost) { _, _ in save() }
        .onChange(of: laborPricePerM2) { _, _ in save() }
        .onChange(of: minimumPricePerPiece) { _, _ in save() }
        .onChange(of: simpleMultiplier) { _, _ in save() }
        .onChange(of: mediumMultiplier) { _, _ in save() }
        .onChange(of: complexMultiplier) { _, _ in save() }
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar", action: onDone)
                }
            }
        }
    }
}
