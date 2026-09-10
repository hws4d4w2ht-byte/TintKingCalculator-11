import SwiftUI
import AppKit

// MARK: - Ramen tinten

// Standaard tint-prijzen zijn verplaatst naar PriceListStore.defaultData (zie PriceListStore.swift)
// en worden nu beheerd via het tabblad "Prijslijst".

struct TintCalculatorView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore

    @State private var selectedBaseID = "Geen basispakket"
    @State private var selectedExtraIDs: Set<String> = []
    @State private var selectedExtraOrder: [String] = []
    @State private var quantities: [String: Int] = [:]
    @State private var manualBasePrice: Double? = nil
    @State private var manualExtraPrices: [String: Double] = [:]
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    private var tintBasePackages: [TintPriceItem] {
        priceListStore.data.tintBasePackages.map { TintPriceItem($0.name, $0.price, $0.category) }
    }

    private var tintExtras: [TintPriceItem] {
        priceListStore.data.tintExtras.map { TintPriceItem($0.name, $0.price, $0.category) }
    }

    private var base: TintPriceItem {
        tintBasePackages.first(where: { $0.id == selectedBaseID }) ?? tintBasePackages[0]
    }

    private var selectedExtras: [TintPriceItem] {
        let ordered = selectedExtraOrder.compactMap { id in
            tintExtras.first(where: { $0.id == id && selectedExtraIDs.contains(id) })
        }
        let missing = tintExtras.filter { selectedExtraIDs.contains($0.id) && !selectedExtraOrder.contains($0.id) }
        return ordered + missing
    }

    private func moveTintExtra(id: String, direction: Int) {
        guard let index = selectedExtraOrder.firstIndex(of: id) else { return }
        let target = index + direction
        guard selectedExtraOrder.indices.contains(target) else { return }
        selectedExtraOrder.swapAt(index, target)
    }

    private var effectiveBasePrice: Double {
        manualBasePrice ?? base.price
    }

    private func effectiveExtraPrice(for item: TintPriceItem) -> Double {
        manualExtraPrices[item.id] ?? item.price
    }

    private var total: Double {
        effectiveBasePrice + selectedExtras.reduce(0) { partial, item in
            partial + effectiveExtraPrice(for: item) * Double(quantities[item.id] ?? 1)
        }
    }

    private var tintDiscount: Double {
        discountValue(total: total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var tintFinalIncludingVAT: Double {
        afterDiscount(total: total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var tintFinalExcludingVAT: Double {
        excludingVAT(fromIncludingVAT: tintFinalIncludingVAT)
    }

    private var lineItems: [QuoteItem] {
        var items: [QuoteItem] = []
        if base.price > 0 {
            items.append(QuoteItem(name: base.name, price: effectiveBasePrice))
        }
        for item in selectedExtras {
            let qty = quantities[item.id] ?? 1
            let qtyText = qty > 1 ? "\(qty)x " : ""
            items.append(QuoteItem(name: "\(qtyText)\(item.name)", price: effectiveExtraPrice(for: item) * Double(qty)))
        }
        if tintDiscount > 0 {
            items.append(QuoteItem(name: "Korting", price: -tintDiscount))
        }
        return items
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ramen tinten")
                        .font(.largeTitle.bold())
                    Text("Dezelfde 3-stappenopbouw als de websitecalculator: kies een basispakket, voeg losse ruiten toe en controleer het totaal.")
                        .foregroundStyle(.secondary)

                    LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $requestStore.linkedCustomerID)

                    VehicleInfoCard(store: requestStore)

                    GroupBox("1. Kies basispakket") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Pakket", selection: $selectedBaseID) {
                                ForEach(["Los samenstellen", "B-Stijl", "A-Stijl", "Merkspecifiek"], id: \.self) { category in
                                    Section(category) {
                                        ForEach(tintBasePackages.filter { $0.category == category }) { item in
                                            Text(item.price > 0 ? "\(item.name) – \(item.price.formatted(currency))" : item.name)
                                                .tag(item.id)
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedBaseID) { _, _ in
                                manualBasePrice = nil
                            }

                            if base.price > 0 {
                                HStack {
                                    Text("Basisprijs")
                                    Spacer()
                                    AppNumberField(
                                        placeholder: "Prijs",
                                        value: Binding(
                                            get: { effectiveBasePrice },
                                            set: { manualBasePrice = $0 }
                                        )
                                    )
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 85)
                                    Text("€")
                                        .foregroundStyle(.secondary)

                                    if manualBasePrice != nil {
                                        Button {
                                            manualBasePrice = nil
                                        } label: {
                                            Image(systemName: "arrow.counterclockwise")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Herstel standaardprijs")
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("2. Extra / losse ruiten") {
                        VStack(spacing: 0) {
                            ForEach(tintExtras) { item in
                                HStack(spacing: 12) {
                                    Toggle(isOn: Binding(
                                        get: { selectedExtraIDs.contains(item.id) },
                                        set: { enabled in
                                            if enabled {
                                                selectedExtraIDs.insert(item.id)
                                                if !selectedExtraOrder.contains(item.id) {
                                                    selectedExtraOrder.append(item.id)
                                                }
                                                if quantities[item.id] == nil { quantities[item.id] = 1 }
                                            } else {
                                                selectedExtraIDs.remove(item.id)
                                                selectedExtraOrder.removeAll { $0 == item.id }
                                                manualExtraPrices.removeValue(forKey: item.id)
                                            }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                            Text(item.category)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if selectedExtraIDs.contains(item.id) {
                                        Stepper(
                                            "\(quantities[item.id] ?? 1)x",
                                            value: Binding(
                                                get: { quantities[item.id] ?? 1 },
                                                set: { quantities[item.id] = $0 }
                                            ),
                                            in: 1...10
                                        )
                                        .frame(width: 95)
                                    }

                                    if selectedExtraIDs.contains(item.id) {
                                        AppNumberField(
                                            placeholder: "Prijs",
                                            value: Binding(
                                                get: { effectiveExtraPrice(for: item) },
                                                set: { manualExtraPrices[item.id] = $0 }
                                            )
                                        )
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 75)
                                        Text("€")
                                            .foregroundStyle(.secondary)

                                        if manualExtraPrices[item.id] != nil {
                                            Button {
                                                manualExtraPrices.removeValue(forKey: item.id)
                                            } label: {
                                                Image(systemName: "arrow.counterclockwise")
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Herstel standaardprijs")
                                        }
                                    } else {
                                        Text(item.price, format: currency)
                                            .frame(width: 85, alignment: .trailing)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)

                                if item.id != tintExtras.last?.id {
                                    Divider()
                                }
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

                        if tintDiscount > 0 {
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
                                Text(-tintDiscount, format: currency)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(tintFinalIncludingVAT, format: currency)
                            .font(.system(size: 42, weight: .bold))
                        Text("incl. btw")

                        Divider()

                        LabeledContent("Excl. btw") {
                            Text(tintFinalExcludingVAT, format: currency).fontWeight(.semibold)
                        }
                        LabeledContent("Btw 21%") {
                            Text(tintFinalIncludingVAT - tintFinalExcludingVAT, format: currency)
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

                        if base.price > 0 {
                            HStack {
                                Text(base.name)
                                Spacer()
                                Text(effectiveBasePrice, format: currency)
                                    .fontWeight(.semibold)
                            }
                        }

                        ForEach(Array(selectedExtras.enumerated()), id: \.element.id) { index, item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    if (quantities[item.id] ?? 1) > 1 {
                                        Text("\(quantities[item.id] ?? 1)x")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(effectiveExtraPrice(for: item) * Double(quantities[item.id] ?? 1), format: currency)
                                    .fontWeight(.semibold)

                                Button {
                                    moveTintExtra(id: item.id, direction: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    moveTintExtra(id: item.id, direction: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == selectedExtras.count - 1)
                            }
                        }

                        if base.price == 0 && selectedExtras.isEmpty {
                            Text("Nog geen werkzaamheden geselecteerd.")
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Button {
                            requestStore.add(category: "Ramen tinten", items: lineItems, total: tintFinalIncludingVAT)
                        } label: {
                            Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                        }
                        .disabled(tintFinalIncludingVAT <= 0)
                    }
                    .cardStyle()

                    Button("Wis calculator") {
                        selectedBaseID = "Geen basispakket"
                        selectedExtraIDs.removeAll()
                        selectedExtraOrder.removeAll()
                        quantities.removeAll()
                        manualBasePrice = nil
                        manualExtraPrices.removeAll()
                        discountMode = .none
                        discountPercentage = 0
                        discountFixedAmount = 0
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 360, idealWidth: 430)
        }
    }
}
