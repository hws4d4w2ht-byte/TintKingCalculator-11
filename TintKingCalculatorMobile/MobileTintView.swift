import SwiftUI
import UIKit

/// Mobiele versie van de Ramen tinten-calculator van de Mac-app.
/// Zelfde 3-stappenlogica en dezelfde prijslijst (via PriceListStore), maar in
/// één doorlopende, verticale lijst in plaats van twee kolommen naast elkaar.
struct MobileTintView: View {
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
    @State private var showExcludingVAT = false

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

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

    private var emailSummaryText: String {
        offerteEmailTemplate(
            vehicleLines: requestStore.vehicleInfoLines,
            items: lineItems,
            totalLabel: "TOTAAL incl. BTW",
            total: tintFinalIncludingVAT,
            showExcludingVATBreakdown: showExcludingVAT
        )
    }

    /// Dezelfde opmaak als de e-mailtekst — zodat beide kopieerknoppen er
    /// hetzelfde uitzien.
    private var whatsAppSummaryText: String { emailSummaryText }

    private func resetCalculator() {
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

    var body: some View {
        List {
            Section {
                LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $requestStore.linkedCustomerID)
            }

            Section {
                MobileVehicleInfoCard(store: requestStore)
            }

            Section("1. Kies basispakket") {
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
                .onChange(of: selectedBaseID) { _, _ in
                    manualBasePrice = nil
                }

                if base.price > 0 {
                    HStack {
                        Text("Basisprijs")
                        Spacer()
                        AppNumberField(
                            placeholder: "Prijs",
                            value: Binding(get: { effectiveBasePrice }, set: { manualBasePrice = $0 })
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 85)
                        Text("€").foregroundStyle(.secondary)

                        if manualBasePrice != nil {
                            Button {
                                manualBasePrice = nil
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("2. Extra / losse ruiten") {
                ForEach(tintExtras) { item in
                    VStack(alignment: .leading, spacing: 8) {
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

                        if selectedExtraIDs.contains(item.id) {
                            HStack {
                                Stepper(
                                    "\(quantities[item.id] ?? 1)x",
                                    value: Binding(get: { quantities[item.id] ?? 1 }, set: { quantities[item.id] = $0 }),
                                    in: 1...10
                                )
                                Spacer()
                                AppNumberField(
                                    placeholder: "Prijs",
                                    value: Binding(get: { effectiveExtraPrice(for: item) }, set: { manualExtraPrices[item.id] = $0 })
                                )
                                .multilineTextAlignment(.trailing)
                                .frame(width: 65)
                                Text("€").foregroundStyle(.secondary)

                                if manualExtraPrices[item.id] != nil {
                                    Button {
                                        manualExtraPrices.removeValue(forKey: item.id)
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } else {
                            Text(item.price, format: currency)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("3. Prijs") {
                VStack(alignment: .leading, spacing: 8) {
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
                        .font(.system(size: 36, weight: .bold))
                    Text("incl. btw")
                        .foregroundStyle(.secondary)

                    Divider()

                    LabeledContent("Excl. btw") {
                        Text(tintFinalExcludingVAT, format: currency).fontWeight(.semibold)
                    }
                    LabeledContent("Btw 21%") {
                        Text(tintFinalIncludingVAT - tintFinalExcludingVAT, format: currency)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Korting") {
                MobileDiscountSection(mode: $discountMode, percentage: $discountPercentage, fixedAmount: $discountFixedAmount)
            }

            Section("Samenvatting") {
                if base.price > 0 {
                    HStack {
                        Text(base.name)
                        Spacer()
                        Text(effectiveBasePrice, format: currency).fontWeight(.semibold)
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

                        MobileReorderButtons(
                            canMoveUp: index != 0,
                            canMoveDown: index != selectedExtras.count - 1,
                            moveUp: { moveTintExtra(id: item.id, direction: -1) },
                            moveDown: { moveTintExtra(id: item.id, direction: 1) }
                        )
                    }
                }

                if base.price == 0 && selectedExtras.isEmpty {
                    Text("Nog geen werkzaamheden geselecteerd.")
                        .foregroundStyle(.secondary)
                }

                Toggle("Toon excl. btw en btw-bedrag bij kopiëren", isOn: $showExcludingVAT)
                    .font(.caption)

                MobileActionButtons(
                    whatsAppText: { whatsAppSummaryText },
                    whatsAppPhone: { customerStore.customer(withID: requestStore.linkedCustomerID)?.whatsAppPhone },
                    emailText: { emailSummaryText },
                    addToRequest: {
                        requestStore.add(category: "Ramen tinten", items: lineItems, total: tintFinalIncludingVAT)
                    },
                    addDisabled: tintFinalIncludingVAT <= 0
                )
                .listRowSeparator(.hidden)
            }

            Section {
                Button("Wis calculator", role: .destructive, action: resetCalculator)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
        .listSectionSpacing(.compact)
        .withKeyboardDismiss()
        .navigationTitle("Ramen tinten")
    }
}
