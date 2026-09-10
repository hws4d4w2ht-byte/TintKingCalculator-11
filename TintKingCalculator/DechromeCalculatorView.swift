import SwiftUI
import AppKit

// MARK: - Ontchromen

// Standaard ontchroom-onderdelen zijn verplaatst naar PriceListStore.defaultData (zie PriceListStore.swift)
// en worden nu beheerd via het tabblad "Prijslijst".

struct DechromeCalculatorView: View {
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
    @State private var selectedCalculationID: UUID?
    @State private var calculationName = ""
    @State private var searchText = ""
    @State private var saveFlash = false

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

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

    private var filteredCalculations: [SavedDechromeCalculation] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return savedStore.calculations
        }
        return savedStore.calculations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }


    var body: some View {
        NavigationSplitView {
            savedSidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Ontchromen")
                            .font(.largeTitle.bold())
                        Text("Kies eerst een auto-preset of stel de chrome delete volledig zelf samen. Presetprijzen uit je prijslijst worden automatisch gebruikt.")
                            .foregroundStyle(.secondary)

                        LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $requestStore.linkedCustomerID)

                        VehicleInfoCard(store: requestStore)

                        GroupBox("Calculatie") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Naam calculatie", text: $calculationName)
                                    .textFieldStyle(.roundedBorder)

                                if let selected = savedStore.calculation(id: selectedCalculationID) {
                                    LabeledContent("Laatst gewijzigd") {
                                        Text(selected.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Nieuwe, nog niet opgeslagen calculatie")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Button {
                                        saveCurrentCalculation()
                                    } label: {
                                        Label("Opslaan", systemImage: "square.and.arrow.down")
                                    }
                                    .disabled(selectedParts.isEmpty)

                                    if saveFlash {
                                        Label("Opgeslagen", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .transition(.opacity)
                                    }
                                }
                            }
                            .padding(8)
                        }

                        GroupBox("1. Kies auto / preset") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Auto", selection: $vehicle) {
                                    Text("Vrij samenstellen").tag("Vrij samenstellen")

                                    Section("Standaard presets") {
                                        ForEach(dechromePresets.keys.sorted(), id: \.self) { name in
                                            Text(name).tag(name)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
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

                                    // Presetnamen bestaan uit merk + model (bijv. "Audi
                                    // E-Tron") — vul het Voertuig-kaartje daar automatisch
                                    // mee, zodat die niet los van de gekozen preset kan
                                    // raken. Bij "Vrij samenstellen" laten we staan wat er
                                    // al stond, want daar is geen preset om vanaf te lezen.
                                    if newVehicle != "Vrij samenstellen" {
                                        let parts = newVehicle.split(separator: " ", maxSplits: 1)
                                        requestStore.vehicleBrand = parts.first.map(String.init) ?? newVehicle
                                        requestStore.vehicleModel = parts.count > 1 ? String(parts[1]) : ""
                                    }
                                }

                                if vehicle == "Lync & Co" {
                                    Text("Let op: volgens de prijslijst zijn de dakrails niet te wrappen.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                        }

                        GroupBox("Onderdeel toevoegen") {
                            HStack {
                                TextField("Naam onderdeel", text: $newPartName)
                                    .textFieldStyle(.roundedBorder)

                                AppNumberField(placeholder: "Prijs", value: $newPartPrice)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)

                                Text("€")
                                    .foregroundStyle(.secondary)

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

                        GroupBox("2. Kies onderdelen") {
                            VStack(spacing: 0) {
                                ForEach(allPartNames, id: \.self) { name in
                                    HStack(spacing: 12) {
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

                                        Spacer()

                                        if selectedParts.contains(name) {
                                            AppNumberField(
                                                placeholder: "Prijs",
                                                value: Binding(
                                                    get: { price(for: name) },
                                                    set: { manualPrices[name] = $0 }
                                                )
                                            )
                                            .multilineTextAlignment(.trailing)
                                            .frame(width: 75)
                                            Text("€")
                                                .foregroundStyle(.secondary)

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
                                                .help("Eigen onderdeel verwijderen")
                                            }
                                        } else {
                                            Text(defaultPrice(for: name), format: currency)
                                                .frame(width: 95, alignment: .trailing)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    Divider()
                                }
                            }
                            .padding(8)
                        }
                    }
                    .padding(24)
                }
                .frame(minWidth: 600)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("3. Prijs")
                            .font(.title.bold())

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Totaalprijs")
                                .foregroundStyle(.secondary)

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
                                .font(.system(size: 42, weight: .bold))
                            Text("incl. btw")

                            Divider()

                            LabeledContent("Excl. btw") {
                                Text(dechromeFinalExcludingVAT, format: currency).fontWeight(.semibold)
                            }
                            LabeledContent("Btw 21%") {
                                Text(dechromeFinalIncludingVAT - dechromeFinalExcludingVAT, format: currency)
                            }
                        }
                        .cardStyle()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Korting").font(.headline)

                            Picker("Korting", selection: $discountMode) {
                                ForEach(DiscountMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if discountMode == .percentage {
                                HStack {
                                    Text("Korting")
                                    Spacer()
                                    AppNumberField(placeholder: "0", value: $discountPercentage)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 75)
                                    Text("%")
                                }
                            } else if discountMode == .fixed {
                                HStack {
                                    Text("Korting")
                                    Spacer()
                                    AppNumberField(placeholder: "0", value: $discountFixedAmount)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 85)
                                    Text("€")
                                }
                            }
                        }
                        .cardStyle()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Samenvatting").font(.headline)

                            if orderedSelectedParts.isEmpty {
                                Text("Nog geen onderdelen geselecteerd.")
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(Array(orderedSelectedParts.enumerated()), id: \.element) { index, name in
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text(price(for: name), format: currency)
                                        .fontWeight(.semibold)

                                    Button {
                                        moveDechromePart(name: name, direction: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)

                                    Button {
                                        moveDechromePart(name: name, direction: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == orderedSelectedParts.count - 1)
                                }
                            }

                            Divider()

                            Button {
                                requestStore.add(category: "Ontchromen", items: lineItems, total: dechromeFinalIncludingVAT)
                            } label: {
                                Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                            }
                            .disabled(dechromeFinalIncludingVAT <= 0)
                        }
                        .cardStyle()

                        Button("Wis calculator") {
                            newCalculation()
                        }
                    }
                    .padding(24)
                }
                .frame(minWidth: 360, idealWidth: 430)
            }
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

    private var savedSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCalculationID) {
                Section("Opgeslagen calculaties") {
                    if filteredCalculations.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "Nog geen calculaties" : "Geen resultaten",
                            systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "Stel een calculatie samen en klik op Opslaan." : "Probeer een andere zoekterm.")
                        )
                    } else {
                        ForEach(filteredCalculations) { calc in
                            DechromeCalculationRow(calculation: calc, currency: currency)
                                .tag(calc.id)
                                .contextMenu {
                                    Button("Dupliceren") { duplicateCalculation(calc.id) }
                                    Divider()
                                    Button("Verwijderen", role: .destructive) { deleteCalculation(calc.id) }
                                }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Zoek calculatie")
            .onChange(of: selectedCalculationID) { _, newValue in
                guard let newValue else { return }
                loadCalculation(newValue)
            }
            .onAppear {
                // Haalt bij het openen van dit scherm eerst de laatste stand op —
                // zodat een wijziging die op de telefoon (of Mac elders) is
                // opgeslagen hier ook verschijnt zonder dat er handmatig op het
                // synchroniseer-knopje gedrukt hoeft te worden.
                Task { await savedStore.syncWithCloud() }
            }

            Divider()

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
                Spacer()
                Button {
                    Task { await savedStore.syncWithCloud() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Synchroniseer nu met iCloud")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            HStack {
                Button {
                    newCalculation()
                } label: {
                    Label("Nieuw", systemImage: "plus")
                }

                Spacer()

                if let selectedCalculationID {
                    Menu {
                        Button("Dupliceren") { duplicateCalculation(selectedCalculationID) }
                        Button("Verwijderen", role: .destructive) { deleteCalculation(selectedCalculationID) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(10)
        }
        .navigationTitle("Calculaties")
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
        selectedCalculationID = nil
        calculationName = ""
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
}

struct DechromeCalculationRow: View {
    let calculation: SavedDechromeCalculation
    let currency: FloatingPointFormatStyle<Double>.Currency

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(calculation.displayName)
                .fontWeight(.semibold)
                .lineLimit(1)
            HStack {
                Text(calculation.modifiedAt, format: .dateTime.day().month().year())
                Spacer()
                Text(calculation.total, format: currency)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
