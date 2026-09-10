import SwiftUI
import UIKit

/// Mobiele versie van de Snijfolie-calculator: een lijst van stickers/ontwerpen,
/// elk met eigen afmeting, materiaal en snijcomplexiteit. Prijs per regel =
/// oppervlakte × materiaalprijs per m² × complexiteitsfactor.
struct MobileSnijfolieView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore

    @State private var items: [CutFoilLineItem] = []
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0
    @State private var showSettings = false

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }
    private var areaFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL"))
    }

    private var materials: [PriceListEntry] { priceListStore.data.cutFoilMaterials ?? [] }

    // Instellingen (rolbreedte, marge, kosten) komen uit de Prijslijst, zodat ze
    // bewaard blijven en je ze zelf kunt bijsturen via de instellingenknop.
    private var startupCost: Double { priceListStore.cutFoilStartupCost }
    private var laborPricePerM2: Double { priceListStore.cutFoilLaborPricePerM2 }
    private var minimumPricePerPiece: Double { priceListStore.cutFoilMinimumPricePerPiece }
    private var usableWidthCm: Double { max(priceListStore.cutFoilRollWidthCm - priceListStore.cutFoilMarginCm, 0) }

    private func materialPrice(for materialID: String) -> Double {
        materials.first(where: { $0.name == materialID })?.price ?? 0
    }

    private func price(for item: CutFoilLineItem) -> Double {
        item.price(pricePerM2: materialPrice(for: item.materialID), usableWidthCm: usableWidthCm, laborPricePerM2: laborPricePerM2, minimumPricePerPiece: minimumPricePerPiece, complexityMultiplier: priceListStore.cutFoilMultiplier(for: item.complexity))
    }

    private func pricePerPiece(for item: CutFoilLineItem) -> Double {
        item.pricePerPiece(pricePerM2: materialPrice(for: item.materialID), usableWidthCm: usableWidthCm, laborPricePerM2: laborPricePerM2, minimumPricePerPiece: minimumPricePerPiece, complexityMultiplier: priceListStore.cutFoilMultiplier(for: item.complexity))
    }

    private func addItem() {
        guard let first = materials.first else { return }
        items.append(CutFoilLineItem(materialID: first.name))
    }

    private func duplicateItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let source = items[index]
        let copy = CutFoilLineItem(
            name: source.name,
            materialID: source.materialID,
            widthCm: source.widthCm,
            heightCm: source.heightCm,
            quantity: source.quantity,
            complexity: source.complexity
        )
        items.insert(copy, at: index + 1)
    }

    private func moveItem(id: UUID, direction: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    private var materialSubtotal: Double { items.reduce(0) { $0 + price(for: $1) } }
    private var subtotal: Double { materialSubtotal + max(startupCost, 0) }

    private var discount: Double {
        discountValue(total: subtotal, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var finalIncludingVAT: Double {
        afterDiscount(total: subtotal, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var finalExcludingVAT: Double { excludingVAT(fromIncludingVAT: finalIncludingVAT) }

    private var lineItems: [QuoteItem] {
        var result: [QuoteItem] = []
        for item in items {
            let qtyText = item.quantity > 1 ? "\(item.quantity)x " : ""
            result.append(QuoteItem(name: "\(qtyText)\(item.displayName) (\(item.complexity.rawValue))", price: price(for: item)))
        }
        if startupCost > 0 {
            result.append(QuoteItem(name: "Opstartkosten", price: startupCost))
        }
        if discount > 0 {
            result.append(QuoteItem(name: "Korting", price: -discount))
        }
        return result
    }

    private var emailSummaryText: String {
        offerteEmailTemplate(vehicleLines: [], items: lineItems, totalLabel: "TOTAAL incl. BTW", total: finalIncludingVAT)
    }

    private var whatsAppSummaryText: String {
        var lines: [String] = []
        for item in items {
            let qtyText = item.quantity > 1 ? "\(item.quantity)x " : ""
            lines.append("- \(qtyText)\(item.displayName) (\(item.complexity.rawValue)): \(price(for: item).formatted(currency))")
        }
        if lines.isEmpty { lines.append("Nog geen stickers toegevoegd.") }
        if startupCost > 0 {
            lines.append("Opstartkosten: \(startupCost.formatted(currency))")
        }
        if discount > 0 {
            lines.append("Korting: -\(discount.formatted(currency))")
        }
        lines.append("Totaal: \(finalIncludingVAT.formatted(currency)) incl. btw")
        return lines.joined(separator: "\n")
    }

    private func resetCalculator() {
        items.removeAll()
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rol: \(priceListStore.cutFoilRollWidthCm.formatted(areaFormat)) cm − \(priceListStore.cutFoilMarginCm.formatted(areaFormat)) cm marge")
                        Text("\(usableWidthCm.formatted(areaFormat)) cm bruikbaar")
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Instellingen", systemImage: "gearshape")
                    }
                }
            }

            if materials.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nog geen snijfolie-materialen ingesteld")
                            .font(.headline)
                        Text("Voeg eerst een materiaal (met prijs per m²) toe bij Prijslijst, onder \"Snijfolie – materialen\".")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section("Stickers / ontwerpen") {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("Naam (optioneel)", text: $item.name)
                                Spacer()
                                Button {
                                    duplicateItem(id: item.id)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }

                            Picker("Materiaal", selection: $item.materialID) {
                                ForEach(materials) { material in
                                    Text(material.price > 0 ? "\(material.name) – \(material.price.formatted(currency))/m²" : material.name)
                                        .tag(material.name)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack {
                                AppNumberField(placeholder: "Breedte", value: $item.widthCm, decimals: 0...1)
                                    .frame(width: 60)
                                Text("cm ×")
                                AppNumberField(placeholder: "Hoogte", value: $item.heightCm, decimals: 0...1)
                                    .frame(width: 60)
                                Text("cm")
                                Spacer()
                                HStack(spacing: 4) {
                                    TextField(
                                        "Aantal",
                                        value: Binding(
                                            get: { item.quantity },
                                            set: { item.quantity = min(max($0, 1), 200) }
                                        ),
                                        format: .number
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 40)
                                    Text("x").foregroundStyle(.secondary)
                                    Stepper("", value: $item.quantity, in: 1...200)
                                        .labelsHidden()
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Picker("Complexiteit", selection: $item.complexity) {
                                    ForEach(CutComplexity.allCases) { level in
                                        Text(level.rawValue).tag(level)
                                    }
                                }
                                .pickerStyle(.segmented)
                                Text(item.complexity.helpText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if item.exceedsRollWidth(usableWidthCm: usableWidthCm) {
                                Text("⚠️ Breder dan de bruikbare rolbreedte (\(usableWidthCm.formatted(areaFormat)) cm) — past niet op deze rol.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text("\(item.piecesPerRow(usableWidthCm: usableWidthCm)) per rij · \(item.rowsNeeded(usableWidthCm: usableWidthCm)) rij(en) · \(item.rollLengthCm(usableWidthCm: usableWidthCm).formatted(areaFormat)) cm rol")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("\(item.areaM2(usableWidthCm: usableWidthCm).formatted(areaFormat)) m²")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(price(for: item), format: currency)
                                        .fontWeight(.semibold)
                                    Text("\(pricePerPiece(for: item).formatted(currency)) / stuk")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if item.laborSurcharge(laborPricePerM2: laborPricePerM2, complexityMultiplier: priceListStore.cutFoilMultiplier(for: item.complexity)) > 0 {
                                Text("Materiaal \(item.materialCost(pricePerM2: materialPrice(for: item.materialID), usableWidthCm: usableWidthCm).formatted(currency)) + arbeid \(item.laborSurcharge(laborPricePerM2: laborPricePerM2, complexityMultiplier: priceListStore.cutFoilMultiplier(for: item.complexity)).formatted(currency))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Button {
                        addItem()
                    } label: {
                        Label("Sticker toevoegen", systemImage: "plus.circle")
                    }
                }
            }

            Section("Prijs") {
                VStack(alignment: .leading, spacing: 8) {
                    if discount > 0 {
                        HStack {
                            Text("Voor korting")
                            Spacer()
                            Text(subtotal, format: currency)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Korting")
                            Spacer()
                            Text(-discount, format: currency)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(finalIncludingVAT, format: currency)
                        .font(.system(size: 36, weight: .bold))
                    Text("incl. btw")
                        .foregroundStyle(.secondary)

                    Divider()

                    LabeledContent("Excl. btw") {
                        Text(finalExcludingVAT, format: currency).fontWeight(.semibold)
                    }
                    LabeledContent("Btw 21%") {
                        Text(finalIncludingVAT - finalExcludingVAT, format: currency)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Korting") {
                MobileDiscountSection(mode: $discountMode, percentage: $discountPercentage, fixedAmount: $discountFixedAmount)
            }

            Section("Samenvatting") {
                if startupCost > 0 {
                    HStack {
                        Text("Opstartkosten")
                        Spacer()
                        Text(startupCost, format: currency)
                            .fontWeight(.semibold)
                    }
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                            Text("\(item.complexity.rawValue) · \(item.areaM2(usableWidthCm: usableWidthCm).formatted(areaFormat)) m² · \(pricePerPiece(for: item).formatted(currency))/stuk")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(price(for: item), format: currency)
                            .fontWeight(.semibold)

                        MobileReorderButtons(
                            canMoveUp: index != 0,
                            canMoveDown: index != items.count - 1,
                            moveUp: { moveItem(id: item.id, direction: -1) },
                            moveDown: { moveItem(id: item.id, direction: 1) }
                        )
                    }
                }

                if items.isEmpty {
                    Text("Nog geen stickers toegevoegd.")
                        .foregroundStyle(.secondary)
                }

                MobileActionButtons(
                    whatsAppText: { whatsAppSummaryText },
                    whatsAppPhone: { customerStore.customer(withID: requestStore.linkedCustomerID)?.whatsAppPhone },
                    emailText: { emailSummaryText },
                    addToRequest: {
                        requestStore.add(category: "Snijfolie", items: lineItems, total: finalIncludingVAT)
                    },
                    addDisabled: finalIncludingVAT <= 0
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
        .navigationTitle("Snijfolie")
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                CutFoilSettingsView(priceListStore: priceListStore, onDone: { showSettings = false })
            }
        }
    }
}
