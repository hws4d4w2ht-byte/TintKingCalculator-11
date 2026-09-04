import SwiftUI
import AppKit

private enum TintKingTheme {
    static let cornerRadius: CGFloat = 16
}

private struct TintKingCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TintKingTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TintKingTheme.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 5)
    }
}

private struct TintKingHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}






private struct VehicleInfoCard: View {
    @ObservedObject var store: RequestStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voertuig").font(.headline)
                Spacer()
                Button {
                    store.clearVehicleInfo()
                } label: {
                    Label("Wis voertuig", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            Text("Dit voertuig wordt vastgelegd op het moment dat je op ‘Toevoegen aan aanvraag’ klikt — zo kun je meerdere auto's na elkaar toevoegen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Merk", text: $store.vehicleBrand)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $store.vehicleModel)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("Carrosserie", selection: $store.vehicleBodyType) {
                    Text("Kies carrosserie").tag("")
                    ForEach(carBodyTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .pickerStyle(.menu)
                TextField("Bouwjaar", text: $store.vehicleYear)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .cardStyle()
    }
}

struct ContentView: View {
    @StateObject private var requestStore = RequestStore()
    @StateObject private var priceListStore = PriceListStore()
    @StateObject private var measurementStore = MeasurementStore()
    @StateObject private var moneybirdSettings = MoneybirdSettingsStore()
    @StateObject private var productStore = ProductStore()

    var body: some View {
        TabView {
            MontageCalculatorView(moneybirdSettings: moneybirdSettings)
                .tabItem {
                    Label("Offerte / montage", systemImage: "doc.text")
                }

            TintCalculatorView(requestStore: requestStore, priceListStore: priceListStore)
                .tabItem {
                    Label("Ramen tinten", systemImage: "car.side")
                }

            DechromeCalculatorView(requestStore: requestStore, priceListStore: priceListStore)
                .tabItem {
                    Label("Ontchromen", systemImage: "sparkles")
                }

            RollCalculatorView()
                .tabItem {
                    Label("Rolcalculator", systemImage: "ruler")
                }

            SnijfolieCalculatorView(requestStore: requestStore, priceListStore: priceListStore)
                .tabItem {
                    Label("Snijfolie", systemImage: "scissors")
                }

            NavigationStack {
                MeasureView(store: measurementStore)
            }
                .tabItem {
                    Label("Meten", systemImage: "ruler")
                }

            ProductListView(store: productStore, requestStore: requestStore)
                .tabItem {
                    Label("Producten", systemImage: "shippingbox")
                }

            CombinedRequestView(store: requestStore, moneybirdSettings: moneybirdSettings)
                .tabItem {
                    Label("Aanvraag", systemImage: "cart")
                }

            PriceListView(store: priceListStore)
                .tabItem {
                    Label("Prijslijst", systemImage: "list.bullet.rectangle")
                }
        }
        .tint(.green)
        .frame(minWidth: 1050, minHeight: 720)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.green.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Ramen tinten



// Standaard tint-prijzen zijn verplaatst naar PriceListStore.defaultData (zie PriceListStore.swift)
// en worden nu beheerd via het tabblad "Prijslijst".

private struct TintCalculatorView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore

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

    private var emailSummaryText: String {
        offerteEmailTemplate(
            vehicleLines: requestStore.vehicleInfoLines,
            items: lineItems,
            totalLabel: "TOTAAL incl. BTW",
            total: tintFinalIncludingVAT
        )
    }

    private var whatsAppSummaryText: String {
        var lines: [String] = []
        if base.price > 0 {
            lines.append("- \(base.name): \(effectiveBasePrice.formatted(currency))")
        }
        for item in selectedExtras {
            let qty = quantities[item.id] ?? 1
            let qtyText = qty > 1 ? "\(qty)x " : ""
            lines.append("- \(qtyText)\(item.name): \((effectiveExtraPrice(for: item) * Double(qty)).formatted(currency))")
        }
        if lines.isEmpty { lines.append("Nog geen werkzaamheden geselecteerd.") }
        if tintDiscount > 0 {
            lines.append("Korting: -\(tintDiscount.formatted(currency))")
        }
        lines.append("Totaal: \(tintFinalIncludingVAT.formatted(currency)) incl. btw")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ramen tinten")
                        .font(.largeTitle.bold())
                    Text("Dezelfde 3-stappenopbouw als de websitecalculator: kies een basispakket, voeg losse ruiten toe en controleer het totaal.")
                        .foregroundStyle(.secondary)

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

                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(whatsAppSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(emailSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                            }

                            Button {
                                requestStore.add(category: "Ramen tinten", items: lineItems, total: tintFinalIncludingVAT)
                            } label: {
                                Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                            }
                            .disabled(tintFinalIncludingVAT <= 0)
                        }
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

// MARK: - Snijfolie

private struct SnijfolieCalculatorView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var priceListStore: PriceListStore

    @State private var items: [CutFoilLineItem] = []
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0
    @State private var showSettings = false

    private var currency: FloatingPointFormatStyle<Double>.Currency { .currency(code: "EUR").locale(Locale(identifier: "nl_NL")) }
    private var areaFormat: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL")) }

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
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Snijfolie")
                                .font(.largeTitle.bold())
                            Text("Prijs per sticker/ontwerp: oppervlakte × materiaalprijs per m² × een factor voor hoeveel wiedwerk (handwerk) het snijwerk kost.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Label("Instellingen", systemImage: "gearshape")
                        }
                    }

                    HStack {
                        Text("Rol: \(priceListStore.cutFoilRollWidthCm.formatted(areaFormat)) cm − \(priceListStore.cutFoilMarginCm.formatted(areaFormat)) cm marge = \(usableWidthCm.formatted(areaFormat)) cm bruikbaar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if materials.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nog geen snijfolie-materialen ingesteld")
                                .font(.headline)
                            Text("Voeg eerst een materiaal (met prijs per m²) toe bij het tabblad Prijslijst, onder \"Snijfolie – materialen\".")
                                .foregroundStyle(.secondary)
                        }
                        .cardStyle()
                    } else {
                        GroupBox("Stickers / ontwerpen") {
                            VStack(spacing: 0) {
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
                                            .help("Regel dupliceren")

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

                                        HStack {
                                            AppNumberField(placeholder: "Breedte", value: $item.widthCm, decimals: 0...1)
                                                .frame(width: 70)
                                            Text("cm ×")
                                            AppNumberField(placeholder: "Hoogte", value: $item.heightCm, decimals: 0...1)
                                                .frame(width: 70)
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
                                                .multilineTextAlignment(.trailing)
                                                .frame(width: 44)
                                                Text("x").foregroundStyle(.secondary)
                                                Stepper("", value: $item.quantity, in: 1...200)
                                                    .labelsHidden()
                                            }
                                            .frame(width: 110)
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
                                    .padding(.vertical, 10)

                                    if item.id != items.last?.id {
                                        Divider()
                                    }
                                }

                                if items.isEmpty {
                                    Text("Nog geen stickers toegevoegd.")
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                }
                            }
                            .padding(8)
                        }

                        Button {
                            addItem()
                        } label: {
                            Label("Sticker toevoegen", systemImage: "plus.circle")
                        }
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 600)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Prijs")
                        .font(.title.bold())

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Totaalprijs")
                            .foregroundStyle(.secondary)

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
                            .font(.system(size: 42, weight: .bold))
                        Text("incl. btw")

                        Divider()

                        LabeledContent("Excl. btw") {
                            Text(finalExcludingVAT, format: currency).fontWeight(.semibold)
                        }
                        LabeledContent("Btw 21%") {
                            Text(finalIncludingVAT - finalExcludingVAT, format: currency)
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

                                Button {
                                    moveItem(id: item.id, direction: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    moveItem(id: item.id, direction: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == items.count - 1)
                            }
                        }

                        if items.isEmpty {
                            Text("Nog geen stickers toegevoegd.")
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(whatsAppSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(emailSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                            }

                            Button {
                                requestStore.add(category: "Snijfolie", items: lineItems, total: finalIncludingVAT)
                            } label: {
                                Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                            }
                            .disabled(finalIncludingVAT <= 0)
                        }
                    }
                    .cardStyle()

                    Button("Wis calculator", action: resetCalculator)
                }
                .padding(24)
            }
            .frame(minWidth: 360, idealWidth: 430)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                CutFoilSettingsView(priceListStore: priceListStore, onDone: { showSettings = false })
            }
        }
    }
}

// MARK: - Ontchromen



// Standaard ontchroom-onderdelen zijn verplaatst naar PriceListStore.defaultData (zie PriceListStore.swift)
// en worden nu beheerd via het tabblad "Prijslijst".




private struct DechromeCalculatorView: View {
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

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

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

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ontchromen")
                        .font(.largeTitle.bold())
                    Text("Kies eerst een auto-preset of stel de chrome delete volledig zelf samen. Presetprijzen uit je prijslijst worden automatisch gebruikt.")
                        .foregroundStyle(.secondary)

                    VehicleInfoCard(store: requestStore)

                    GroupBox("1. Kies auto / preset") {
                        VStack(alignment: .leading, spacing: 12) {
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
                            .pickerStyle(.menu)
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

                            HStack {
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

                        Text("Je kunt ieder extra onderdeel toevoegen. Daarna kun je de calculatie als nieuwe preset opslaan of je eigen preset bijwerken.")
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

                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(whatsAppSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(emailSummaryText, forType: .string)
                            } label: {
                                Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                            }

                            Button {
                                requestStore.add(category: "Ontchromen", items: lineItems, total: dechromeFinalIncludingVAT)
                            } label: {
                                Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                            }
                            .disabled(dechromeFinalIncludingVAT <= 0)
                        }
                    }
                    .cardStyle()

                    Button("Wis calculator") {
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
                }
                .padding(24)
            }
            .frame(minWidth: 360, idealWidth: 430)
        }
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



private struct CutPlannerLine: Identifiable, Hashable {
    let id: UUID
    var widthCm: Double
    var quantity: Int

    init(id: UUID = UUID(), widthCm: Double = 0, quantity: Int = 1) {
        self.id = id
        self.widthCm = widthCm
        self.quantity = quantity
    }
}

private struct RollCalculatorView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case cut = "Snijplanner"
        case foil = "Folie"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .cut

    // Snijplanner
    @State private var maxWidthCm: Double = 152
    @State private var cutLines: [CutPlannerLine] = [
        CutPlannerLine(widthCm: 0, quantity: 1)
    ]

    // Folie
    @State private var rollWidthCm: Double = 152
    @State private var rollLengthM: Double = 25
    @State private var rollCount: Int = 1
    @State private var wastePercent: Double = 10

    private var usedWidthCm: Double {
        cutLines.reduce(0) { partial, line in
            partial + max(line.widthCm, 0) * Double(max(line.quantity, 0))
        }
    }

    private var remainingWidthCm: Double {
        maxWidthCm - usedWidthCm
    }

    private var baseLinearMeters: Double {
        max(rollLengthM, 0) * Double(max(rollCount, 0))
    }

    private var linearMetersWithWaste: Double {
        baseLinearMeters * (1 + max(wastePercent, 0) / 100.0)
    }

    private var areaWithWaste: Double {
        (max(rollWidthCm, 0) / 100.0) * linearMetersWithWaste
    }

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL"))
    }

    private var cutResultText: String {
        var lines: [String] = [
            "Snijplanner",
            "Max breedte: \(maxWidthCm.formatted(numberFormat)) cm",
            ""
        ]

        for line in cutLines where line.widthCm > 0 && line.quantity > 0 {
            lines.append("• \(line.quantity)x \(line.widthCm.formatted(numberFormat)) cm")
        }

        lines.append("")
        lines.append("Gebruikt: \(usedWidthCm.formatted(numberFormat)) cm")
        lines.append("Resterend: \(remainingWidthCm.formatted(numberFormat)) cm")
        return lines.joined(separator: "\n")
    }

    private var foilResultText: String {
        """
        Folie calculator
        Rolbreedte: \(rollWidthCm.formatted(numberFormat)) cm
        Lengte per rol: \(rollLengthM.formatted(numberFormat)) m
        Aantal rollen: \(rollCount)
        Snijverlies: \(wastePercent.formatted(numberFormat))%

        Strekkende meters zonder snijverlies: \(baseLinearMeters.formatted(numberFormat)) m
        Strekkende meters incl. snijverlies: \(linearMetersWithWaste.formatted(numberFormat)) m
        Oppervlak incl. snijverlies: \(areaWithWaste.formatted(numberFormat)) m²
        """
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TintKingHeader(
                        title: "Rolcalculator",
                        subtitle: "Snijplanner en foliecalculator in één scherm.",
                        icon: "ruler"
                    )

                    Picker("Calculator", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .cut {
                        cutPlannerInput
                    } else {
                        foilCalculatorInput
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 620)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Resultaat")
                        .font(.title.bold())

                    if mode == .cut {
                        cutPlannerResult
                    } else {
                        foilCalculatorResult
                    }

                    Spacer()
                }
                .padding(24)
            }
            .frame(minWidth: 360, idealWidth: 430)
        }
    }

    private var cutPlannerInput: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Max breedte").font(.headline)

                HStack {
                    Text("Max breedte")
                    Spacer()
                    AppNumberField(placeholder: "152", value: $maxWidthCm)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("cm")
                }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 12) {
                Text("Maten & aantallen").font(.headline)

                ForEach($cutLines) { $line in
                    let index = cutLines.firstIndex(where: { $0.id == line.id }) ?? 0
                    HStack(spacing: 12) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)

                        AppNumberField(placeholder: "Breedte", value: $line.widthCm)
                            .frame(width: 120)

                        Text("cm")

                        Stepper(value: $line.quantity, in: 1...999) {
                            Text("\(line.quantity)x")
                                .frame(minWidth: 50, alignment: .leading)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            cutLines.removeAll { $0.id == line.id }
                            if cutLines.isEmpty {
                                cutLines = [CutPlannerLine(widthCm: 0, quantity: 1)]
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    cutLines.append(CutPlannerLine(widthCm: 0, quantity: 1))
                } label: {
                    Label("Regel toevoegen", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    maxWidthCm = 152
                    cutLines = [CutPlannerLine(widthCm: 0, quantity: 1)]
                } label: {
                    Label("Alles resetten", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
            .cardStyle()
        }
    }

    private var cutPlannerResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Metric(title: "Gebruikt", value: "\(usedWidthCm.formatted(numberFormat)) cm")
                Metric(title: "Resterend", value: "\(remainingWidthCm.formatted(numberFormat)) cm")

                if remainingWidthCm < 0 {
                    Label(
                        "Je zit \(abs(remainingWidthCm).formatted(numberFormat)) cm over de maximale breedte.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            .cardStyle()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cutResultText, forType: .string)
            } label: {
                Label("Kopieer snij-resultaat", systemImage: "doc.on.doc")
            }
        }
    }

    private var foilCalculatorInput: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Folie calculator").font(.headline)

                HStack {
                    Text("Rolbreedte")
                    Spacer()
                    AppNumberField(placeholder: "152", value: $rollWidthCm)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    Text("cm")
                }

                HStack {
                    Text("Lengte per rol")
                    Spacer()
                    AppNumberField(placeholder: "25", value: $rollLengthM)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    Text("m")
                }

                Stepper(value: $rollCount, in: 1...999) {
                    HStack {
                        Text("Aantal rollen")
                        Spacer()
                        Text("\(rollCount)")
                    }
                }

                HStack {
                    Text("Snijverlies")
                    Spacer()
                    AppNumberField(placeholder: "10", value: $wastePercent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    Text("%")
                }
            }
            .cardStyle()

            HStack {
                Button {
                    rollWidthCm = 152
                    rollLengthM = 25
                    rollCount = 1
                    wastePercent = 10
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }

                Spacer()
            }
        }
    }

    private var foilCalculatorResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Metric(
                    title: "Strekkende meters zonder snijverlies",
                    value: "\(baseLinearMeters.formatted(numberFormat)) m"
                )
                Metric(
                    title: "Strekkende meters incl. snijverlies",
                    value: "\(linearMetersWithWaste.formatted(numberFormat)) m"
                )
                Metric(
                    title: "Oppervlak incl. snijverlies",
                    value: "\(areaWithWaste.formatted(numberFormat)) m²"
                )
            }
            .cardStyle()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(foilResultText, forType: .string)
            } label: {
                Label("Kopieer folie-resultaat", systemImage: "doc.on.doc")
            }

            Text("Tip: als je een rol splitst in meerdere kleine rollen, vul je bij ‘Aantal rollen’ het aantal deelrollen in en bij ‘Lengte per rol’ de lengte van één deelrol.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CombinedRequestView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0
    @State private var showExcludingVAT = true

    @State private var showMoneybirdSettings = false
    @State private var isExportingToMoneybird = false
    @State private var moneybirdResultMessage: String?
    @State private var moneybirdExportSucceeded = false
    @State private var showMoneybirdResult = false

    /// Identificeert het item dat op dit moment bewerkt wordt (op positie,
    /// niet op waarde — zie `RequestStore.updateItem`).
    private struct EditingItemRef: Equatable {
        let lineID: UUID
        let itemIndex: Int
    }
    @State private var editingItem: EditingItemRef?
    @State private var editItemName = ""
    @State private var editItemPrice: Double = 0

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    private var requestDiscount: Double {
        discountValue(total: store.total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var finalIncludingVAT: Double {
        afterDiscount(total: store.total, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var finalExcludingVAT: Double {
        excludingVAT(fromIncludingVAT: finalIncludingVAT)
    }

    /// Alleen omschrijving + bedrag per regel, voor de Moneybird-export.
    /// Geen klant- of btw-logica hier: dat doet Robin zelf na in Moneybird.
    private var moneybirdLines: [MoneybirdExportService.EstimateLine] {
        // De prijzen in de app zijn incl. btw (voor de klantweergave). Moneybird telt
        // zelf automatisch 21% btw op bij een regel, dus hier moeten we excl. btw
        // aanleveren — anders wordt de btw twee keer gerekend.
        var result: [MoneybirdExportService.EstimateLine] = []
        for line in store.lines {
            for item in line.items {
                result.append(contentsOf: moneybirdLines(for: item, category: line.category, priceIncludesVAT: line.priceIncludesVAT))
            }
        }
        if requestDiscount > 0 {
            result.append(MoneybirdExportService.EstimateLine(description: "Korting", price: -excludingVAT(fromIncludingVAT: requestDiscount)))
        }
        return result
    }

    /// Eén regel-item wordt hier zo nodig opgesplitst in meerdere
    /// Moneybird-regels: de hoofdregel (titel + eventuele notitie) en, als er
    /// gekozen submenu-opties met een eigen (meer)prijs bij horen, een aparte
    /// regel per optie — zodat die meerprijs ook in de offerte apart
    /// zichtbaar is, in plaats van onzichtbaar verwerkt in het totaalbedrag
    /// van de hoofdregel.
    private func moneybirdLines(for item: QuoteItem, category: String, priceIncludesVAT: Bool) -> [MoneybirdExportService.EstimateLine] {
        // Staat de regel al als "excl. btw" gemarkeerd (bijv. Striping), dan gaat
        // het bedrag ongewijzigd mee — Moneybird telt er zelf 21% btw bovenop.
        // Anders wordt de btw er eerst afgehaald, zoals bij de rest van de app.
        func moneybirdPrice(_ value: Double) -> Double {
            priceIncludesVAT ? excludingVAT(fromIncludingVAT: value) : value
        }
        var title = item.displayTitle
        if let note = item.displayNote {
            title += " — \(note)"
        }
        let optionsTotal = item.optionBreakdown.reduce(0) { $0 + $1.price }
        let basePrice = item.price - optionsTotal
        var lines = [MoneybirdExportService.EstimateLine(description: "\(category) – \(title)", price: moneybirdPrice(basePrice))]
        for option in item.optionBreakdown {
            lines.append(MoneybirdExportService.EstimateLine(
                description: "\(category) – \(item.displayTitle) — \(option.name): \(breakdownPriceText(option.price))",
                price: moneybirdPrice(option.price)
            ))
        }
        return lines
    }

    private func exportToMoneybird() {
        guard moneybirdSettings.isConfigured else {
            showMoneybirdSettings = true
            return
        }
        isExportingToMoneybird = true
        let lines = moneybirdLines
        Task {
            do {
                let result = try await MoneybirdExportService.exportEstimate(lines: lines, settings: moneybirdSettings)
                if let draftNumber = result.draftNumber {
                    moneybirdResultMessage = "Concept-offerte #\(draftNumber) aangemaakt in Moneybird bij klant \"App klant\"."
                } else {
                    moneybirdResultMessage = "Concept-offerte aangemaakt in Moneybird bij klant \"App klant\"."
                }
                moneybirdExportSucceeded = true
            } catch {
                moneybirdResultMessage = error.localizedDescription
                moneybirdExportSucceeded = false
            }
            isExportingToMoneybird = false
            showMoneybirdResult = true
        }
    }

    private var emailCombinedText: String {
        if store.lines.isEmpty {
            return "Nog geen calculaties aan deze aanvraag toegevoegd."
        }

        var blocks: [String] = []
        for line in store.lines {
            var block: [String] = []
            if !line.vehicleLines.isEmpty {
                block.append("VOERTUIG")
                block.append(String(repeating: "-", count: 8))
                block.append(contentsOf: line.vehicleLines)
                block.append("")
            }
            block.append("OFFERTE – \(line.category)")
            block.append(String(repeating: "-", count: 7))
            block.append("")
            block.append(padColumn("Omschrijving") + "Prijs incl. BTW")
            for item in line.items {
                block.append(padColumn(item.name) + dutchPriceString(item.price))
            }
            block.append("")
            block.append(padColumn("Subtotaal") + dutchPriceString(line.total))
            blocks.append(block.joined(separator: "\n"))
        }

        var out = blocks.joined(separator: "\n\n")
        out += "\n\n"
        if requestDiscount > 0 {
            out += padColumn("Korting") + dutchPriceString(-requestDiscount) + "\n"
        }
        let totalLine = padColumn("TOTAAL incl. BTW") + dutchPriceString(finalIncludingVAT)
        let dashes = String(repeating: "-", count: max(48, totalLine.count))
        out += dashes + "\n" + totalLine + "\n" + dashes

        if showExcludingVAT {
            out += "\n\n"
            out += padColumn("Totaal excl. btw") + dutchPriceString(finalExcludingVAT) + "\n"
            out += padColumn("Btw 21%") + dutchPriceString(finalIncludingVAT - finalExcludingVAT)
        }

        return out
    }

    private var whatsAppCombinedText: String {
        if store.lines.isEmpty {
            return "Nog geen calculaties aan deze aanvraag toegevoegd."
        }

        var lines: [String] = []

        for line in store.lines {
            lines.append("\(line.category):")
            for item in line.items {
                lines.append("- \(item.name): \(item.price.formatted(currency))")
            }
            lines.append("Subtotaal: \(line.total.formatted(currency))")
            lines.append("")
        }

        if requestDiscount > 0 {
            lines.append("Korting: -\(requestDiscount.formatted(currency))")
        }

        lines.append("Totaal: \(finalIncludingVAT.formatted(currency)) incl. btw")
        return lines.joined(separator: "\n")
    }

    /// Tekst voor één regel van de submenu-prijsopbouw onder een product,
    /// bijv. "+€5,00" voor een meerprijs, of gewoon "€0,00"/"-€5,00" voor nul
    /// of een negatief bedrag (het min-teken komt dan al uit de opmaak zelf).
    private func breakdownPriceText(_ value: Double) -> String {
        let formatted = value.formatted(currency)
        return value > 0 ? "+\(formatted)" : formatted
    }

    /// Eén regel-item in de Aanvraag: gewoon tekst + prijs, of — met het
    /// potlood-icoontje — de volledige tekst en prijs ter plekke te bewerken
    /// (bijv. om een kenteken of gebruikte kleur folie toe te voegen).
    @ViewBuilder
    private func requestItemRow(line: RequestLine, itemIndex: Int, item: QuoteItem) -> some View {
        let ref = EditingItemRef(lineID: line.id, itemIndex: itemIndex)
        if editingItem == ref {
            VStack(alignment: .leading, spacing: 8) {
                // Volledig tekstvlak (in plaats van één regel) omdat de
                // omschrijving vaak lang is — productnaam, gekozen opties en
                // een eigen notitie samen — en zo in één keer overzichtelijk
                // te bewerken is.
                TextField("Omschrijving", text: $editItemName, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    AppNumberField(placeholder: "0,00", value: $editItemPrice)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("€")
                    Spacer()
                    Button {
                        store.updateItem(lineID: line.id, itemIndex: itemIndex, newName: editItemName, newPrice: editItemPrice)
                        editingItem = nil
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Button {
                        editingItem = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                    ForEach(item.optionBreakdown, id: \.self) { option in
                        Text("\(option.name): \(breakdownPriceText(option.price))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = item.displayNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.price, format: currency)
                Button {
                    editingItem = ref
                    editItemName = item.name
                    editItemPrice = item.price
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TintKingHeader(
                        title: "Aanvraag",
                        subtitle: "Combineer werkzaamheden in één nette prijsopgave.",
                        icon: "cart"
                    )

                    if store.lines.isEmpty {
                        ContentUnavailableView(
                            "Nog niets toegevoegd",
                            systemImage: "cart",
                            description: Text("Ga naar Ramen tinten of Ontchromen en klik op ‘Toevoegen aan aanvraag’.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(Array(store.lines.enumerated()), id: \.element.id) { index, line in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(line.category)
                                        .font(.title3.bold())
                                    Spacer()
                                    Text(line.total, format: currency)
                                        .font(.title3.bold())

                                    Button {
                                        store.move(id: line.id, direction: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)

                                    Button {
                                        store.move(id: line.id, direction: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == store.lines.count - 1)

                                    Button(role: .destructive) {
                                        store.remove(id: line.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }

                                HStack(spacing: 6) {
                                    Text("Naar Moneybird:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: Binding(
                                        get: { line.priceIncludesVAT },
                                        set: { store.setPriceIncludesVAT(lineID: line.id, includesVAT: $0) }
                                    )) {
                                        Text("prijs incl. btw").tag(true)
                                        Text("prijs excl. btw").tag(false)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 260)
                                    .labelsHidden()
                                }
                                .help("Bepaalt alleen hoe deze regel naar Moneybird gestuurd wordt: bij \"incl. btw\" haalt de app zelf de btw eraf, bij \"excl. btw\" gaat het bedrag ongewijzigd mee en telt Moneybird de btw er zelf bij op.")

                                if !line.vehicleLines.isEmpty {
                                    ForEach(line.vehicleLines, id: \.self) { vehicleLine in
                                        Text(vehicleLine)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                ForEach(Array(line.items.enumerated()), id: \.offset) { itemIndex, item in
                                    requestItemRow(line: line, itemIndex: itemIndex, item: item)
                                }

                                Divider()

                                HStack {
                                    Text("Subtotaal")
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text(line.total, format: currency)
                                        .fontWeight(.semibold)
                                }
                            }
                            .cardStyle()
                        }
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 600)

            VStack(alignment: .leading, spacing: 18) {
                TintKingHeader(
                    title: "Totaal",
                    subtitle: "Samenvatting van deze aanvraag",
                    icon: "eurosign.circle"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Totaal aanvraag")
                        .foregroundStyle(.secondary)

                    if requestDiscount > 0 {
                        HStack {
                            Text("Voor korting")
                            Spacer()
                            Text(store.total, format: currency)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Korting")
                            Spacer()
                            Text(-requestDiscount, format: currency)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(finalIncludingVAT, format: currency)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("incl. btw")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if showExcludingVAT {
                        Divider()

                        LabeledContent("Excl. btw") {
                            Text(finalExcludingVAT, format: currency)
                                .fontWeight(.semibold)
                        }
                        LabeledContent("Btw 21%") {
                            Text(finalIncludingVAT - finalExcludingVAT, format: currency)
                        }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Weergave prijsopgave").font(.headline)

                    Toggle("Toon excl. btw en btw-bedrag", isOn: $showExcludingVAT)

                    Text(showExcludingVAT
                         ? "Zakelijke weergave: excl. btw, btw-bedrag en incl. btw."
                         : "Klantweergave: alleen de prijs inclusief btw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(whatsAppCombinedText, forType: .string)
                    } label: {
                        Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                    }
                    .disabled(store.lines.isEmpty)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(emailCombinedText, forType: .string)
                    } label: {
                        Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                    }
                    .disabled(store.lines.isEmpty)
                }

                HStack {
                    Button {
                        exportToMoneybird()
                    } label: {
                        if isExportingToMoneybird {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Exporteer naar Moneybird", systemImage: "arrow.up.doc")
                        }
                    }
                    .disabled(store.lines.isEmpty || isExportingToMoneybird)

                    Button {
                        showMoneybirdSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Moneybird-instellingen")
                }

                Button(role: .destructive) {
                    store.clear()
                    discountMode = .none
                    discountPercentage = 0
                    discountFixedAmount = 0
                } label: {
                    Label("Wis aanvraag", systemImage: "trash")
                }
                .disabled(store.lines.isEmpty)

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 360, idealWidth: 430)
        }
        .sheet(isPresented: $showMoneybirdSettings) {
            NavigationStack {
                MoneybirdSettingsView(settings: moneybirdSettings, onDone: { showMoneybirdSettings = false })
            }
        }
        .alert(moneybirdExportSucceeded ? "Geëxporteerd naar Moneybird" : "Export mislukt", isPresented: $showMoneybirdResult) {
            Button("OK") {}
        } message: {
            Text(moneybirdResultMessage ?? "")
        }
    }
}


struct MontageCalculatorView: View {
    @StateObject private var store = ProjectStore()
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @State private var input = CalculationInput()
    @State private var settings = CalculatorSettings()
    @State private var selectedProjectID: UUID?
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var saveFlash = false
    @State private var discountMode: DiscountMode = .none
    @State private var discountPercentage: Double = 0
    @State private var discountFixedAmount: Double = 0
    @State private var showDetailedBreakdown = false

    @State private var showMoneybirdSettings = false
    @State private var isExportingToMoneybird = false
    @State private var moneybirdResultMessage: String?
    @State private var moneybirdExportSucceeded = false
    @State private var showMoneybirdResult = false

    private var result: CalculationResult { calculate(input: input, settings: settings) }

    private var montagePriceBeforeDiscountExclVAT: Double {
        input.chosenPrice > 0 ? input.chosenPrice : result.suggestedPrice
    }

    private var montageDiscountExclVAT: Double {
        discountValue(total: montagePriceBeforeDiscountExclVAT, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var montageFinalExclVAT: Double {
        afterDiscount(total: montagePriceBeforeDiscountExclVAT, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var montageFinalInclVAT: Double {
        includingVAT(fromExcludingVAT: montageFinalExclVAT)
    }

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    private var filteredProjects: [SavedProject] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return store.projects
        }
        return store.projects.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } content: {
            calculatorForm
                .navigationSplitViewColumnWidth(min: 430, ideal: 500, max: 620)
        } detail: {
            resultDetail
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $settings)
        }
        .alert("Opslagfout", isPresented: Binding(
            get: { store.lastError != nil },
            set: { isPresented in
                if !isPresented { store.clearError() }
            }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "Onbekende fout")
        }
        .sheet(isPresented: $showMoneybirdSettings) {
            NavigationStack {
                MoneybirdSettingsView(settings: moneybirdSettings, onDone: { showMoneybirdSettings = false })
            }
        }
        .alert(moneybirdExportSucceeded ? "Geëxporteerd naar Moneybird" : "Export mislukt", isPresented: $showMoneybirdResult) {
            Button("OK") {}
        } message: {
            Text(moneybirdResultMessage ?? "")
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProjectID) {
                Section("Opgeslagen calculaties") {
                    if filteredProjects.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "Nog geen projecten" : "Geen resultaten",
                            systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "Maak een nieuwe calculatie en klik op Opslaan." : "Probeer een andere zoekterm.")
                        )
                    } else {
                        ForEach(filteredProjects) { project in
                            ProjectRow(project: project, currency: currency)
                                .tag(project.id)
                                .contextMenu {
                                    Button("Dupliceren") { duplicate(project.id) }
                                    Divider()
                                    Button("Verwijderen", role: .destructive) { delete(project.id) }
                                }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Zoek klant of project")
            .onChange(of: selectedProjectID) { _, newValue in
                guard let project = store.project(id: newValue) else { return }
                input = project.input
                settings = project.settings
            }

            Divider()

            HStack(spacing: 4) {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Synchroniseren…")
                } else if let lastSyncedAt = store.lastSyncedAt {
                    Image(systemName: "checkmark.icloud")
                    Text("Gesynchroniseerd \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Image(systemName: "icloud.slash")
                    Text("Nog niet gesynchroniseerd")
                }
                Spacer()
                Button {
                    Task { await store.syncWithCloud() }
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
                    newProject()
                } label: {
                    Label("Nieuw", systemImage: "plus")
                }

                Spacer()

                if let selectedProjectID {
                    Menu {
                        Button("Dupliceren") { duplicate(selectedProjectID) }
                        Button("Verwijderen", role: .destructive) { delete(selectedProjectID) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(10)
        }
        .navigationTitle("Projecten")
    }

    private var calculatorForm: some View {
        Form {
            Section("Project") {
                TextField("Klant / project / omschrijving", text: $input.projectName)
                if let selectedProject = store.project(id: selectedProjectID) {
                    LabeledContent("Laatst gewijzigd") {
                        Text(selectedProject.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nieuwe, nog niet opgeslagen calculatie")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Inkoop materialen") {
                ForEach(input.materials.indices, id: \.self) { index in
                    let lineID = input.materials[index].id

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            TextField(
                                "Omschrijving, bijv. Probo print",
                                text: Binding(
                                    get: { input.materials[index].name },
                                    set: { input.materials[index].name = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            Button(role: .destructive) {
                                removeMaterialLine(id: lineID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Inkoopregel verwijderen")
                        }

                        HStack {
                            CurrencyField(
                                title: "Inkoop",
                                value: Binding(
                                    get: { input.materials[index].cost },
                                    set: { input.materials[index].cost = $0 }
                                )
                            )
                            PercentageField(
                                title: "Opslag",
                                value: Binding(
                                    get: { input.materials[index].markup },
                                    set: { input.materials[index].markup = $0 }
                                )
                            )
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Doorberekend")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(input.materials[index].charged, format: currency)
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 110, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    addMaterialLine()
                } label: {
                    Label("Inkoopregel toevoegen", systemImage: "plus.circle.fill")
                }

                Divider()

                LabeledContent("Totale inkoop") {
                    Text(result.materialCost, format: currency).fontWeight(.semibold)
                }
                LabeledContent("Doorberekend materiaal") {
                    Text(result.materialCharged, format: currency).fontWeight(.semibold)
                }
                LabeledContent("Materiaalopbrengst") {
                    Text(result.materialCharged - result.materialCost, format: currency).fontWeight(.semibold)
                }

                CurrencyField(title: "Verzend-/orderkosten", value: $input.shipping)
            }

            Section("Tijd en montage") {
                NumberField(title: "Voorbereiding werkplaats", suffix: "uur", value: $input.prepHours)
                NumberField(title: "Montage op locatie", suffix: "uur", value: $input.installHours)
                Stepper("Aantal personen: \(input.installers)", value: $input.installers, in: 1...10)
                NumberField(title: "Reistijd totaal", suffix: "uur", value: $input.travelHours)
                NumberField(title: "Kilometers totaal", suffix: "km", value: $input.kilometers)
            }

            Section("Overige kosten") {
                CurrencyField(title: "Parkeren / tol", value: $input.parkingToll)
                CurrencyField(title: "Hoogwerker / steiger / huur", value: $input.rental)
                CurrencyField(title: "Overige directe kosten", value: $input.otherDirectCosts)
            }

            Section("Klusfactoren") {
                Picker("Moeilijkheid", selection: $input.difficulty) {
                    ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Risico/faalkans", selection: $input.risk) {
                    ForEach(RiskLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Spoedklus", isOn: $input.rush)
            }

            Section("Jouw prijsgevoel") {
                CurrencyField(title: "Gekozen verkoopprijs excl. btw", value: $input.chosenPrice)
            }

            Section("Korting") {
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
                    CurrencyField(title: "Korting excl. btw", value: $discountFixedAmount)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(input.projectName.isEmpty ? "Nieuwe calculatie" : input.projectName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    saveCurrentProject()
                } label: {
                    Label(saveFlash ? "Opgeslagen" : "Opslaan", systemImage: saveFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)

                Button {
                    showSettings = true
                } label: {
                    Label("Instellingen", systemImage: "gearshape")
                }
            }
        }
    }

    private var resultDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                priceCard
                breakdownCard
                quoteCard
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Berekende richtprijs").font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.suggestedPrice, format: currency)
                        .font(.system(size: 38, weight: .bold))
                    Text("excl. btw")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(includingVAT(fromExcludingVAT: result.suggestedPrice), format: currency)
                        .font(.title2.bold())
                    Text("incl. btw")
                        .foregroundStyle(.secondary)
                }
            }

            if montageDiscountExclVAT > 0 {
                Divider()
                LabeledContent("Korting excl. btw") {
                    Text(-montageDiscountExclVAT, format: currency)
                }
                LabeledContent("Na korting excl. btw") {
                    Text(montageFinalExclVAT, format: currency).fontWeight(.bold)
                }
                LabeledContent("Na korting incl. btw") {
                    Text(montageFinalInclVAT, format: currency).fontWeight(.bold)
                }
            }

            HStack(spacing: 18) {
                Metric(title: "Inkoop materiaal", value: result.materialCost.formatted(currency))
                Metric(title: "Na directe kosten", value: result.amountAfterDirectCosts.formatted(currency))
                Metric(title: "Effectief / gewerkt uur", value: result.effectivePerWorkedHour.formatted(currency))
            }

            if input.chosenPrice > 0 {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jouw gekozen prijs: \(input.chosenPrice.formatted(currency)) excl. btw")
                        Text("\(includingVAT(fromExcludingVAT: input.chosenPrice).formatted(currency)) incl. btw")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(result.chosenDifference >= 0 ? "+\(result.chosenDifference.formatted(currency))" : result.chosenDifference.formatted(currency))
                        .fontWeight(.bold)
                        .foregroundStyle(result.chosenDifference >= 0 ? .green : .red)
                }
            }
        }
        .cardStyle()
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Opbouw").font(.title2.bold())
            BreakdownRow("Materialen incl. opslag", result.materialCharged)
            BreakdownRow("Voorbereiding", result.prepLabor)
            BreakdownRow("Montage (\(result.installHoursTotal.formatted(.number.precision(.fractionLength(1)))) uur)", result.installLabor)
            BreakdownRow("Reistijd", result.travelCharge)
            BreakdownRow("Kilometers", result.kmCharge)
            BreakdownRow("Overige directe kosten", result.directExtras)
            Divider()
            BreakdownRow("Subtotaal", result.subtotal, bold: true)
            HStack {
                Text("Moeilijkheid")
                Spacer()
                Text("× \(input.difficulty.factor.formatted(.number.precision(.fractionLength(2))))")
            }
            HStack {
                Text("Risico-opslag")
                Spacer()
                Text(input.risk.percentage, format: .percent)
            }
            if input.rush {
                HStack {
                    Text("Spoedopslag")
                    Spacer()
                    Text(settings.rushPercentage, format: .percent)
                }
            }
        }
        .cardStyle()
    }

    private var vehicleInfoLines: [String] {
        formatVehicleInfoLines(
            brand: input.vehicleBrand ?? "",
            model: input.vehicleModel ?? "",
            bodyType: input.vehicleBodyType ?? "",
            year: input.vehicleYear ?? ""
        )
    }

    private func formatQty(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private var simpleLineItems: [QuoteItem] {
        let title = input.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Montagewerk op locatie" : input.projectName
        var items = [QuoteItem(name: title, price: includingVAT(fromExcludingVAT: montagePriceBeforeDiscountExclVAT))]
        if montageDiscountExclVAT > 0 {
            items.append(QuoteItem(name: "Korting", price: -includingVAT(fromExcludingVAT: montageDiscountExclVAT)))
        }
        return items
    }

    /// Elke kostenpost los (materialen, uren, hoogwerker, enz.), zodat de klant
    /// kan zien hoe de prijs is opgebouwd — i.p.v. één totaalregel.
    private var detailedLineItemsExclVAT: [(name: String, amount: Double)] {
        var items: [(name: String, amount: Double)] = []
        for material in input.materials {
            let name = material.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, material.charged > 0 else { continue }
            items.append((name, material.charged))
        }
        if input.prepHours > 0 {
            items.append(("Voorbereiding werkplaats (\(formatQty(input.prepHours)) uur)", result.prepLabor))
        }
        if result.installHoursTotal > 0 {
            items.append(("Montage op locatie (\(formatQty(result.installHoursTotal)) uur)", result.installLabor))
        }
        if input.travelHours > 0 {
            items.append(("Reistijd (\(formatQty(input.travelHours)) uur)", result.travelCharge))
        }
        if input.kilometers > 0 {
            items.append(("Kilometervergoeding (\(formatQty(input.kilometers)) km)", result.kmCharge))
        }
        if input.shipping > 0 {
            items.append(("Verzend-/orderkosten", input.shipping))
        }
        if input.parkingToll > 0 {
            items.append(("Parkeren / tol", input.parkingToll))
        }
        if input.rental > 0 {
            items.append(("Hoogwerker / steiger / huur", input.rental))
        }
        if input.otherDirectCosts > 0 {
            items.append(("Overige directe kosten", input.otherDirectCosts))
        }

        let itemsTotal = items.reduce(0) { $0 + $1.amount }
        let surcharge = montagePriceBeforeDiscountExclVAT - itemsTotal
        if abs(surcharge) > 0.005 {
            items.append(("Moeilijkheids-, risico- en overige toeslag", surcharge))
        }
        return items
    }

    private var detailedLineItems: [QuoteItem] {
        var items = detailedLineItemsExclVAT.map { QuoteItem(name: $0.name, price: includingVAT(fromExcludingVAT: $0.amount)) }
        if montageDiscountExclVAT > 0 {
            items.append(QuoteItem(name: "Korting", price: -includingVAT(fromExcludingVAT: montageDiscountExclVAT)))
        }
        return items
    }

    private var lineItems: [QuoteItem] {
        showDetailedBreakdown ? detailedLineItems : simpleLineItems
    }

    private var quoteText: String {
        offerteEmailTemplate(
            vehicleLines: vehicleInfoLines,
            items: lineItems,
            totalLabel: "TOTAAL incl. BTW",
            total: montageFinalInclVAT
        )
    }

    private var whatsAppQuoteText: String {
        var lines = lineItems.map { "\($0.name): \($0.price.formatted(currency))" }
        lines.append("Totaal: \(montageFinalInclVAT.formatted(currency)) incl. btw")
        return lines.joined(separator: "\n")
    }

    /// Alleen omschrijving + bedrag per regel, voor de Moneybird-export.
    /// Geen klant- of btw-logica hier: dat doet Robin zelf na in Moneybird.
    private var moneybirdLines: [MoneybirdExportService.EstimateLine] {
        // De prijzen in lineItems zijn incl. btw (voor de klantweergave). Moneybird
        // telt zelf automatisch 21% btw op bij een regel, dus hier excl. btw
        // aanleveren — anders wordt de btw twee keer gerekend.
        lineItems.map { MoneybirdExportService.EstimateLine(description: $0.name, price: excludingVAT(fromIncludingVAT: $0.price)) }
    }

    private func exportToMoneybird() {
        guard moneybirdSettings.isConfigured else {
            showMoneybirdSettings = true
            return
        }
        isExportingToMoneybird = true
        let lines = moneybirdLines
        Task {
            do {
                let result = try await MoneybirdExportService.exportEstimate(lines: lines, settings: moneybirdSettings)
                if let draftNumber = result.draftNumber {
                    moneybirdResultMessage = "Concept-offerte #\(draftNumber) aangemaakt in Moneybird bij klant \"App klant\"."
                } else {
                    moneybirdResultMessage = "Concept-offerte aangemaakt in Moneybird bij klant \"App klant\"."
                }
                moneybirdExportSucceeded = true
            } catch {
                moneybirdResultMessage = error.localizedDescription
                moneybirdExportSucceeded = false
            }
            isExportingToMoneybird = false
            showMoneybirdResult = true
        }
    }

    private var quoteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Toon uitgesplitst (materialen, uren, hoogwerker, enz.)", isOn: $showDetailedBreakdown)
                .toggleStyle(.switch)

            HStack {
                Text("Offertetekst").font(.title2.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(whatsAppQuoteText, forType: .string)
                } label: {
                    Label("WhatsApp", systemImage: "message.fill")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quoteText, forType: .string)
                } label: {
                    Label("E-mail", systemImage: "envelope.fill")
                }
                Button {
                    exportToMoneybird()
                } label: {
                    if isExportingToMoneybird {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Moneybird", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isExportingToMoneybird)
                Button {
                    showMoneybirdSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Moneybird-instellingen")
            }
            Text(quoteText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .cardStyle()
    }

    @ViewBuilder
    private func BreakdownRow(_ title: String, _ value: Double, bold: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(value, format: currency).fontWeight(bold ? .semibold : .regular)
        }
    }

    private func addMaterialLine() {
        input.materials.append(MaterialLine(name: "", cost: 0, markup: 0.40))
    }

    private func removeMaterialLine(id: UUID) {
        input.materials.removeAll { $0.id == id }
        if input.materials.isEmpty {
            input.materials.append(MaterialLine(name: "", cost: 0, markup: 0.40))
        }
    }

    private func newProject() {
        selectedProjectID = nil
        input = CalculationInput()
    }

    private func saveCurrentProject() {
        selectedProjectID = store.save(input: input, settings: settings, projectID: selectedProjectID)
        withAnimation { saveFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { saveFlash = false }
        }
    }

    private func duplicate(_ id: UUID) {
        guard let newID = store.duplicate(projectID: id), let project = store.project(id: newID) else { return }
        selectedProjectID = newID
        input = project.input
        settings = project.settings
    }

    private func delete(_ id: UUID) {
        store.delete(projectID: id)
        if selectedProjectID == id {
            newProject()
        }
    }
}

private struct ProjectRow: View {
    let project: SavedProject
    let currency: FloatingPointFormatStyle<Double>.Currency

    var body: some View {
        let result = calculate(input: project.input, settings: project.settings)
        VStack(alignment: .leading, spacing: 4) {
            Text(project.displayName)
                .fontWeight(.semibold)
                .lineLimit(1)
            HStack {
                Text(project.modifiedAt, format: .dateTime.day().month().year())
                Spacer()
                Text(result.suggestedPrice, format: currency)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CurrencyField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            AppNumberField(placeholder: "0,00", value: $value, decimals: 2...2)
                .multilineTextAlignment(.trailing)
                .frame(width: 95)
            Text("€").foregroundStyle(.secondary)
        }
    }
}

private struct NumberField: View {
    let title: String
    let suffix: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            AppNumberField(placeholder: "0", value: $value)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
}

private struct PercentageField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            AppNumberField(placeholder: "0", value: Binding(
                get: { value * 100 },
                set: { value = $0 / 100 }
            ), decimals: 0...0)
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            Text("%").foregroundStyle(.secondary)
        }
    }
}

private struct SettingsView: View {
    @Binding var settings: CalculatorSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Instellingen").font(.title.bold())
            Form {
                CurrencyField(title: "Uurtarief werk", value: $settings.hourlyRate)
                CurrencyField(title: "Reistijd per uur", value: $settings.travelHourlyRate)
                CurrencyField(title: "Kilometertarief", value: $settings.kmRate)
                PercentageField(title: "Spoedopslag", value: $settings.rushPercentage)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Gereed") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 330)
    }
}

private extension View {
    func cardStyle() -> some View {
        modifier(TintKingCardModifier())
    }
}
