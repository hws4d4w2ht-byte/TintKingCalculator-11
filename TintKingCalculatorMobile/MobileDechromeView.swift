import SwiftUI
import UIKit

/// Mobiele versie van de Ontchromen-calculator van de Mac-app. Opgeslagen calculaties komen
/// uit de gedeelde, met iCloud gesynchroniseerde DechromeCalculationStore (zie DechromeCalculationStore.swift).
struct MobileDechromeView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @StateObject private var savedStore = DechromeCalculationStore()

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
    @State private var showExcludingVAT = false
    @State private var selectedCalculationID: UUID?
    @State private var calculationName = ""
    @State private var saveFlash = false

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

    private var dechromeBaseParts: [DechromePart] {
        priceListStore.data.dechromeParts.map { DechromePart($0.name, $0.price) }
    }

    private var preset: [String: Double] {
        dechromePresets[vehicle] ?? [:]
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
            total: dechromeFinalIncludingVAT,
            showExcludingVATBreakdown: showExcludingVAT
        )
    }

    /// Dezelfde opmaak als de e-mailtekst — zodat beide kopieerknoppen er
    /// hetzelfde uitzien.
    private var whatsAppSummaryText: String { emailSummaryText }

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

    private func loadCalculation(_ id: UUID) {
        guard let calc = savedStore.calculation(id: id) else { return }
        selectedCalculationID = calc.id
        calculationName = calc.name
        vehicle = "Vrij samenstellen"
        selectedParts = calc.selectedParts
        selectedPartOrder = calc.selectedPartOrder
        manualPrices = calc.manualPrices
        customParts = calc.customParts
        discountMode = calc.discountMode
        discountPercentage = calc.discountPercentage
        discountFixedAmount = calc.discountFixedAmount
    }

    private func newCalculation() {
        resetCalculator()
        selectedCalculationID = nil
        calculationName = ""
    }

    private func saveCurrentCalculation() {
        selectedCalculationID = savedStore.save(
            name: calculationName,
            selectedParts: selectedParts,
            selectedPartOrder: selectedPartOrder,
            manualPrices: currentSelectedPriceMap,
            customParts: customParts,
            discountMode: discountMode,
            discountPercentage: discountPercentage,
            discountFixedAmount: discountFixedAmount,
            id: selectedCalculationID
        )
        if let saved = savedStore.calculation(id: selectedCalculationID) {
            calculationName = saved.name
        }
        withAnimation { saveFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { saveFlash = false }
        }
    }

    private func duplicateCalculation(_ id: UUID) {
        guard let newID = savedStore.duplicate(id: id) else { return }
        loadCalculation(newID)
    }

    private func deleteCalculation(_ id: UUID) {
        savedStore.delete(id: id)
        if selectedCalculationID == id {
            newCalculation()
        }
    }

    var body: some View {
        List {
            Section {
                LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $requestStore.linkedCustomerID)
            }

            Section {
                MobileVehicleInfoCard(store: requestStore)
            }

            Section("Opgeslagen calculaties") {
                TextField("Naam calculatie", text: $calculationName)

                HStack {
                    Button {
                        saveCurrentCalculation()
                    } label: {
                        Label("Opslaan", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selectedParts.isEmpty)

                    Spacer()

                    Button {
                        newCalculation()
                    } label: {
                        Label("Nieuw", systemImage: "plus")
                    }

                    if saveFlash {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if savedStore.calculations.isEmpty {
                    Text("Nog geen calculaties opgeslagen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedStore.calculations) { calc in
                        Button {
                            loadCalculation(calc.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calc.displayName)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(calc.modifiedAt, format: .dateTime.day().month().year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(calc.total, format: currency)
                                    .foregroundStyle(.secondary)
                                if selectedCalculationID == calc.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteCalculation(calc.id)
                            } label: {
                                Label("Verwijder", systemImage: "trash")
                            }
                            Button {
                                duplicateCalculation(calc.id)
                            } label: {
                                Label("Dupliceer", systemImage: "plus.square.on.square")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                duplicateCalculation(calc.id)
                            } label: {
                                Label("Dupliceer", systemImage: "plus.square.on.square")
                            }
                            Button(role: .destructive) {
                                deleteCalculation(calc.id)
                            } label: {
                                Label("Verwijder", systemImage: "trash")
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    if savedStore.isSyncing {
                        ProgressView().controlSize(.small)
                        Text("Synchroniseren…")
                    } else if let lastSyncedAt = savedStore.lastSyncedAt {
                        Image(systemName: "checkmark.icloud")
                        Text("Gesynchroniseerd \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Image(systemName: "icloud.slash")
                        Text("Nog niet gesynchroniseerd")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("1. Kies auto / preset") {
                Picker("Auto", selection: $vehicle) {
                    Text("Vrij samenstellen").tag("Vrij samenstellen")

                    Section("Standaard presets") {
                        ForEach(dechromePresets.keys.sorted(), id: \.self) { name in
                            Text(name).tag(name)
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
                    } else {
                        selectedParts.removeAll()
                        selectedPartOrder.removeAll()
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
                Text("Je kunt ieder extra onderdeel toevoegen. Daarna kun je de calculatie opslaan onder een naam via de kaart hierboven.")
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

                Toggle("Toon excl. btw en btw-bedrag bij kopiëren", isOn: $showExcludingVAT)
                    .font(.caption)

                MobileActionButtons(
                    whatsAppText: { whatsAppSummaryText },
                    whatsAppPhone: { customerStore.customer(withID: requestStore.linkedCustomerID)?.whatsAppPhone },
                    emailText: { emailSummaryText },
                    addToRequest: {
                        requestStore.add(category: "Ontchromen", items: lineItems, total: dechromeFinalIncludingVAT)
                    },
                    addDisabled: dechromeFinalIncludingVAT <= 0
                )
                .listRowSeparator(.hidden)
            }

            Section {
                Button("Wis calculator", role: .destructive, action: newCalculation)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
        .listSectionSpacing(.compact)
        .withKeyboardDismiss()
        .navigationTitle("Ontchromen")
        .onAppear {
            // Haalt bij het openen van dit tabblad eerst de laatste stand op —
            // zodat een wijziging die op de Mac (of elders) is opgeslagen hier
            // ook verschijnt zonder dat er handmatig op het synchroniseer-
            // knopje gedrukt hoeft te worden.
            Task { await savedStore.syncWithCloud() }
        }
        .alert("Opslagfout", isPresented: Binding(
            get: { savedStore.lastError != nil },
            set: { isPresented in
                if !isPresented { savedStore.clearError() }
            }
        )) {
            Button("OK", role: .cancel) { savedStore.clearError() }
        } message: {
            Text(savedStore.lastError ?? "Onbekende fout")
        }
    }
}
