import SwiftUI
import UIKit

/// Mobiele versie van de Ontchromen-calculator van de Mac-app. De presets komen uit
/// de gedeelde, met iCloud gesynchroniseerde DechromePresetStore (zie DechromePresetStore.swift).
struct MobileDechromeView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore
    @StateObject private var customPresetStore = DechromePresetStore()

    @State private var vehicle = "Vrij samenstellen"
    @State private var selectedParts: Set<String> = []
    @State private var selectedPartOrder: [String] = []
    @State private var manualPrices: [String: Double] = [:]
    @State private var customParts: [String: Double] = [:]
    @State private var newPartName = ""
    @State private var newPartPrice: Double = 0
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0
    @State private var showPresetNamePrompt = false
    @State private var pendingPresetName = ""

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

    private var dechromeBaseParts: [DechromePart] {
        priceListStore.data.dechromeParts.map { DechromePart($0.name, $0.price) }
    }

    private var preset: [String: Double] {
        if let builtIn = dechromePresets[vehicle] { return builtIn }
        return customPresetStore.presets.first(where: { $0.name == vehicle })?.prices ?? [:]
    }

    private var isCustomPreset: Bool {
        customPresetStore.presets.contains(where: { $0.name == vehicle })
    }

    private var currentSelectedPriceMap: [String: Double] {
        Dictionary(uniqueKeysWithValues: selectedParts.map { ($0, price(for: $0)) })
    }

    private var orderedSelectedParts: [String] {
        let ordered = selectedPartOrder.filter { selectedParts.contains($0) }
        let missing = selectedParts.filter { !selectedPartOrder.contains($0) }.sorted()
        return ordered + missing
    }

    private func moveDechromePart(name: String, direction: Int) {
        guard let index = selectedPartOrder.firstIndex(of: name) else { return }
        let target = index + direction
        guard selectedPartOrder.indices.contains(target) else { return }
        selectedPartOrder.swapAt(index, target)
    }

    private var allPartNames: [String] {
        let baseNames = dechromeBaseParts.map(\.name)
        let presetNames = preset.keys.filter { !baseNames.contains($0) }
        let customNames = customParts.keys.filter { !baseNames.contains($0) && !presetNames.contains($0) }
        return (baseNames + presetNames + customNames).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func defaultPrice(for name: String) -> Double {
        if let presetPrice = preset[name] { return presetPrice }
        if let customPrice = customParts[name] { return customPrice }
        return dechromeBaseParts.first(where: { $0.name == name })?.basePrice ?? 0
    }

    private func price(for name: String) -> Double {
        manualPrices[name] ?? defaultPrice(for: name)
    }

    private var total: Double {
        selectedParts.reduce(0) { $0 + price(for: $1) }
    }

    private var dechromeDiscount: Double {
        discountValue(total: total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var dechromeFinalIncludingVAT: Double {
        afterDiscount(total: total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var dechromeFinalExcludingVAT: Double {
        excludingVAT(fromIncludingVAT: dechromeFinalIncludingVAT)
    }

    private var lineItems: [QuoteItem] {
        var items: [QuoteItem] = []
        for name in orderedSelectedParts {
            items.append(QuoteItem(name: name, price: price(for: name)))
        }
        if dechromeDiscount > 0 {
            items.append(QuoteItem(name: "Korting", price: -dechromeDiscount))
        }
        return items
    }

    private var emailSummaryText: String {
        offerteEmailTemplate(
            vehicleLines: requestStore.vehicleInfoLines,
            items: lineItems,
            totalLabel: "TOTAAL incl. BTW",
            total: dechromeFinalIncludingVAT
        )
    }

    private var whatsAppSummaryText: String {
        var lines = ["Ontchromen\(vehicle == "Vrij samenstellen" ? "" : " – \(vehicle)")"]
        if selectedParts.isEmpty {
            lines.append("Nog geen onderdelen geselecteerd.")
        } else {
            for name in orderedSelectedParts {
                lines.append("- \(name): \(price(for: name).formatted(currency))")
            }
        }
        if dechromeDiscount > 0 {
            lines.append("Korting: -\(dechromeDiscount.formatted(currency))")
        }
        lines.append("Totaal: \(dechromeFinalIncludingVAT.formatted(currency)) incl. btw")
        return lines.joined(separator: "\n")
    }

    private func resetCalculator() {
        vehicle = "Vrij samenstellen"
        selectedParts.removeAll()
        selectedPartOrder.removeAll()
        manualPrices.removeAll()
        customParts.removeAll()
        newPartName = ""
        newPartPrice = 0
        discountMode = .none
        discountPercentage = 0
        discountFixedAmount = 0
    }

    var body: some View {
        List {
            Section {
                MobileVehicleInfoCard(store: requestStore)
            }

            Section("1. Kies auto / preset") {
                Picker("Auto", selection: $vehicle) {
                    Text("Vrij samenstellen").tag("Vrij samenstellen")

                    Section("Standaard presets") {
                        ForEach(dechromePresets.keys.sorted(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }

                    if !customPresetStore.presets.isEmpty {
                        Section("Mijn presets") {
                            ForEach(customPresetStore.presets.sorted(by: { $0.name < $1.name })) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                    }
                }
                .onChange(of: vehicle) { _, newVehicle in
                    manualPrices.removeAll()
                    customParts.removeAll()

                    if let selectedPreset = dechromePresets[newVehicle] {
                        let names = selectedPreset.keys.sorted()
                        selectedParts = Set(names)
                        selectedPartOrder = names
                    } else if let selectedPreset = customPresetStore.presets.first(where: { $0.name == newVehicle })?.prices {
                        let names = selectedPreset.keys.sorted()
                        selectedParts = Set(names)
                        selectedPartOrder = names
                    } else {
                        selectedParts.removeAll()
                        selectedPartOrder.removeAll()
                    }
                }

                Button {
                    pendingPresetName = vehicle == "Vrij samenstellen" ? "Nieuwe preset" : "\(vehicle) kopie"
                    showPresetNamePrompt = true
                } label: {
                    Label(vehicle == "Vrij samenstellen" ? "Opslaan als preset" : "Preset kopiëren", systemImage: "plus.square.on.square")
                }

                if isCustomPreset {
                    Button {
                        customPresetStore.update(name: vehicle, prices: currentSelectedPriceMap)
                    } label: {
                        Label("Preset bijwerken", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        let oldVehicle = vehicle
                        customPresetStore.delete(name: oldVehicle)
                        vehicle = "Vrij samenstellen"
                        selectedParts.removeAll()
                        selectedPartOrder.removeAll()
                        manualPrices.removeAll()
                        customParts.removeAll()
                    } label: {
                        Label("Verwijder preset", systemImage: "trash")
                    }
                }

                if vehicle == "Lync & Co" {
                    Text("Let op: volgens de prijslijst zijn de dakrails niet te wrappen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Onderdeel toevoegen") {
                TextField("Naam onderdeel", text: $newPartName)
                HStack {
                    AppNumberField(placeholder: "Prijs", value: $newPartPrice)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("€").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let clean = newPartName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        customParts[clean] = newPartPrice
                        manualPrices[clean] = newPartPrice
                        selectedParts.insert(clean)
                        if !selectedPartOrder.contains(clean) {
                            selectedPartOrder.append(clean)
                        }
                        newPartName = ""
                        newPartPrice = 0
                    } label: {
                        Label("Toevoegen", systemImage: "plus")
                    }
                }
                Text("Je kunt ieder extra onderdeel toevoegen. Daarna kun je de calculatie als nieuwe preset opslaan of je eigen preset bijwerken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("2. Kies onderdelen") {
                ForEach(allPartNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(name, isOn: Binding(
                            get: { selectedParts.contains(name) },
                            set: { enabled in
                                if enabled {
                                    selectedParts.insert(name)
                                    if !selectedPartOrder.contains(name) {
                                        selectedPartOrder.append(name)
                                    }
                                } else {
                                    selectedParts.remove(name)
                                    selectedPartOrder.removeAll { $0 == name }
                                    manualPrices.removeValue(forKey: name)
                                }
                            }
                        ))

                        if selectedParts.contains(name) {
                            HStack {
                                AppNumberField(
                                    placeholder: "Prijs",
                                    value: Binding(get: { price(for: name) }, set: { manualPrices[name] = $0 })
                                )
                                .multilineTextAlignment(.trailing)
                                .frame(width: 65)
                                Text("€").foregroundStyle(.secondary)
                                Spacer()

                                if customParts[name] != nil {
                                    Button(role: .destructive) {
                                        selectedParts.remove(name)
                                        selectedPartOrder.removeAll { $0 == name }
                                        manualPrices.removeValue(forKey: name)
                                        customParts.removeValue(forKey: name)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } else {
                            Text(defaultPrice(for: name), format: currency)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("3. Prijs") {
                VStack(alignment: .leading, spacing: 8) {
                    if dechromeDiscount > 0 {
                        HStack {
                            Text("Voor korting")
                            Spacer()
                            Text(total, format: currency)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Korting")
                            Spacer()
                            Text(-dechromeDiscount, format: currency)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(dechromeFinalIncludingVAT, format: currency)
                        .font(.system(size: 36, weight: .bold))
                    Text("incl. btw")
                        .foregroundStyle(.secondary)

                    Divider()

                    LabeledContent("Excl. btw") {
                        Text(dechromeFinalExcludingVAT, format: currency).fontWeight(.semibold)
                    }
                    LabeledContent("Btw 21%") {
                        Text(dechromeFinalIncludingVAT - dechromeFinalExcludingVAT, format: currency)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Korting") {
                MobileDiscountSection(mode: $discountMode, percentage: $discountPercentage, fixedAmount: $discountFixedAmount)
            }

            Section("Samenvatting") {
                if orderedSelectedParts.isEmpty {
                    Text("Nog geen onderdelen geselecteerd.")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(orderedSelectedParts.enumerated()), id: \.element) { index, name in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(price(for: name), format: currency).fontWeight(.semibold)

                        MobileReorderButtons(
                            canMoveUp: index != 0,
                            canMoveDown: index != orderedSelectedParts.count - 1,
                            moveUp: { moveDechromePart(name: name, direction: -1) },
                            moveDown: { moveDechromePart(name: name, direction: 1) }
                        )
                    }
                }

                MobileActionButtons(
                    whatsAppText: { whatsAppSummaryText },
                    emailText: { emailSummaryText },
                    addToRequest: {
                        requestStore.add(category: "Ontchromen", items: lineItems, total: dechromeFinalIncludingVAT)
                    },
                    addDisabled: dechromeFinalIncludingVAT <= 0
                )
                .listRowSeparator(.hidden)
            }

            Section {
                Button("Wis calculator", role: .destructive, action: resetCalculator)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ontchromen")
        .alert("Preset opslaan", isPresented: $showPresetNamePrompt) {
            TextField("Naam preset", text: $pendingPresetName)
            Button("Annuleer", role: .cancel) {}
            Button("Opslaan") {
                let newName = customPresetStore.add(name: pendingPresetName, prices: currentSelectedPriceMap)
                vehicle = newName
            }
        } message: {
            Text("Geef deze preset een naam. Je vindt hem daarna onder Mijn presets.")
        }
    }
}
