import SwiftUI
import UIKit

/// Mobiele versie van de gecombineerde Aanvraag-weergave van de Mac-app.
struct MobileRequestView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var quoteArchiveStore: QuoteArchiveStore
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

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

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

    private var linkedCustomer: Customer? {
        guard let id = store.linkedCustomerID else { return nil }
        return customerStore.customers.first { $0.id == id }
    }

    private var linkedContactId: String? {
        linkedCustomer?.moneybirdContact?.id
    }

    private var exportTargetName: String {
        linkedCustomer?.name.isEmpty == false ? linkedCustomer!.name : "App klant"
    }

    /// Legt de huidige aanvraag vast in het klantarchief (zie "Geschiedenis"
    /// bij Klanten) — alleen zinvol als er een klant gekoppeld is, anders is
    /// er niets om de geschiedenis aan te koppelen.
    private func archiveQuote(channel: String) {
        guard let customer = linkedCustomer else { return }
        quoteArchiveStore.add(customerID: customer.id, channel: channel, summary: combinedQuoteText(), total: finalIncludingVAT)
    }

    private func exportToMoneybird(asInvoice: Bool) {
        guard moneybirdSettings.isConfigured else {
            showMoneybirdSettings = true
            return
        }
        isExportingToMoneybird = true
        let lines = moneybirdLines
        let contactId = linkedContactId
        let targetName = exportTargetName
        Task {
            do {
                if asInvoice {
                    let result = try await MoneybirdExportService.exportInvoice(lines: lines, settings: moneybirdSettings, contactId: contactId)
                    if let draftNumber = result.draftNumber {
                        moneybirdResultMessage = "Conceptfactuur #\(draftNumber) aangemaakt in Moneybird bij klant \"\(targetName)\"."
                    } else {
                        moneybirdResultMessage = "Conceptfactuur aangemaakt in Moneybird bij klant \"\(targetName)\"."
                    }
                } else {
                    let result = try await MoneybirdExportService.exportEstimate(lines: lines, settings: moneybirdSettings, contactId: contactId)
                    if let draftNumber = result.draftNumber {
                        moneybirdResultMessage = "Concept-offerte #\(draftNumber) aangemaakt in Moneybird bij klant \"\(targetName)\"."
                    } else {
                        moneybirdResultMessage = "Concept-offerte aangemaakt in Moneybird bij klant \"\(targetName)\"."
                    }
                }
                moneybirdExportSucceeded = true
                ActivityLogStore.shared.log(
                    asInvoice ? "Factuur verstuurd naar \(targetName)" : "Offerte verstuurd naar \(targetName)",
                    systemImage: "arrow.up.doc",
                    tab: .aanvraag,
                    customerID: linkedCustomer?.id
                )
                archiveQuote(channel: asInvoice ? "Moneybird factuur" : "Moneybird offerte")
            } catch {
                moneybirdResultMessage = error.localizedDescription
                moneybirdExportSucceeded = false
            }
            isExportingToMoneybird = false
            showMoneybirdResult = true
        }
    }

    /// Prijs van één item zoals de klant 'm te zien krijgt: staat de regel op
    /// "excl. btw" (zie `RequestLine.priceIncludesVAT`), dan komt de btw er
    /// hier ook bij — net als bij `RequestLine.displayTotal` — zodat de losse
    /// regels in de tekst optellen tot hetzelfde subtotaal dat eronder staat.
    private func displayPrice(_ price: Double, for line: RequestLine) -> Double {
        line.priceIncludesVAT ? price : includingVAT(fromExcludingVAT: price)
    }

    /// Som van alle regels zoals die in de kopieertekst komt te staan (dus
    /// mét de eventuele incl.-btw-omrekening per regel) — losstaand van
    /// `store.total`, dat altijd het onaangepaste bedrag blijft tonen op het
    /// Aanvraag-scherm zelf.
    private var copyTotal: Double {
        store.lines.reduce(0) { $0 + $1.displayTotal }
    }

    private var copyDiscount: Double {
        discountValue(total: copyTotal, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var copyFinalIncludingVAT: Double {
        afterDiscount(total: copyTotal, mode: discountMode, percentage: discountPercentage, fixedAmount: discountFixedAmount)
    }

    private var copyFinalExcludingVAT: Double {
        excludingVAT(fromIncludingVAT: copyFinalIncludingVAT)
    }

    /// Gedeelde opbouw voor zowel de e-mail- als de WhatsApp-kopieerknop —
    /// dezelfde "streepjes"-opmaak als de losse calculators (Ramen tinten,
    /// Ontchromen), zodat alle kopieerteksten er hetzelfde uitzien.
    private func combinedQuoteText() -> String {
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
            let title = line.category.uppercased()
            block.append(title)
            block.append(String(repeating: "-", count: title.count))
            block.append("")
            block.append(padColumn("Omschrijving") + "Prijs incl. BTW")
            for item in line.items {
                block.append(padColumn(item.name) + dutchPriceString(displayPrice(item.price, for: line)))
            }
            block.append("")
            block.append(padColumn("Subtotaal") + dutchPriceString(line.displayTotal))
            blocks.append(block.joined(separator: "\n"))
        }

        var out = blocks.joined(separator: "\n\n")
        out += "\n\n"
        if copyDiscount > 0 {
            out += padColumn("Korting") + dutchPriceString(-copyDiscount) + "\n"
        }
        // Volgorde bewust excl. btw → btw → incl. btw, met TOTAAL incl. BTW
        // als laatste regel — net als de Totaal-kaart erboven en de Montage-
        // offertetekst.
        let totalLine = padColumn("TOTAAL incl. BTW") + dutchPriceString(copyFinalIncludingVAT)
        let dashes = String(repeating: "-", count: max(48, totalLine.count))
        out += dashes + "\n"
        if showExcludingVAT {
            out += padColumn("Totaal excl. btw") + dutchPriceString(copyFinalExcludingVAT) + "\n"
            out += padColumn("Btw 21%") + dutchPriceString(copyFinalIncludingVAT - copyFinalExcludingVAT) + "\n"
        }
        out += totalLine + "\n" + dashes

        return out
    }

    private var emailCombinedText: String { combinedQuoteText() }

    private var whatsAppCombinedText: String { combinedQuoteText() }

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
                        .textFieldStyle(.roundedBorder)
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
        }
    }

    var body: some View {
        List {
            if store.lines.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nog niets toegevoegd",
                        systemImage: "cart",
                        description: Text("Ga naar Ramen tinten of Ontchromen en tik op 'Toevoegen aan aanvraag'.")
                    )
                }
            } else {
                ForEach(Array(store.lines.enumerated()), id: \.element.id) { index, line in
                    Section {
                        HStack {
                            Text(line.category)
                                .font(.headline)
                            Spacer()
                            Text(line.total, format: currency)
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 4) {
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
                            .labelsHidden()
                        }

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

                        HStack {
                            Text("Subtotaal").fontWeight(.semibold)
                            Spacer()
                            Text(line.total, format: currency).fontWeight(.semibold)
                        }

                        HStack {
                            MobileReorderButtons(
                                canMoveUp: index != 0,
                                canMoveDown: index != store.lines.count - 1,
                                moveUp: { store.move(id: line.id, direction: -1) },
                                moveDown: { store.move(id: line.id, direction: 1) }
                            )
                            Spacer()
                            Button(role: .destructive) {
                                store.remove(id: line.id)
                            } label: {
                                Label("Verwijder", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Totaal") {
                VStack(alignment: .leading, spacing: 8) {
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

                    // Volgorde bewust excl. btw → btw → incl. btw (net als de
                    // opbouw onderaan de kopieertekst), met het eindbedrag
                    // incl. btw als laatste, prominente regel.
                    if showExcludingVAT {
                        LabeledContent("Excl. btw") {
                            Text(finalExcludingVAT, format: currency)
                        }
                        LabeledContent("Btw 21%") {
                            Text(finalIncludingVAT - finalExcludingVAT, format: currency)
                        }
                        Divider()
                    }

                    Text(finalIncludingVAT, format: currency)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("incl. btw")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Weergave prijsopgave") {
                Toggle("Toon excl. btw en btw-bedrag", isOn: $showExcludingVAT)
                Text(showExcludingVAT
                     ? "Zakelijke weergave: excl. btw, btw-bedrag en incl. btw."
                     : "Klantweergave: alleen de prijs inclusief btw.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Korting") {
                MobileDiscountSection(mode: $discountMode, percentage: $discountPercentage, fixedAmount: $discountFixedAmount)
            }

            Section("Voorbeeld van de kopieertekst") {
                Text("Dit is precies de tekst die de knoppen hieronder kopiëren voor WhatsApp of e-mail — inclusief de weergave en korting die je hierboven kiest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(combinedQuoteText())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }

            Section {
                Button {
                    if let phone = linkedCustomer?.whatsAppPhone, let url = WhatsAppLink.url(phone: phone, message: whatsAppCombinedText) {
                        UIApplication.shared.open(url)
                    } else {
                        UIPasteboard.general.string = whatsAppCombinedText
                    }
                    archiveQuote(channel: "WhatsApp")
                } label: {
                    Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.lines.isEmpty)

                Button {
                    UIPasteboard.general.string = emailCombinedText
                    archiveQuote(channel: "E-mail")
                } label: {
                    Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.lines.isEmpty)
            }

            Section {
                LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $store.linkedCustomerID)
            }

            Section {
                Button {
                    exportToMoneybird(asInvoice: false)
                } label: {
                    if isExportingToMoneybird {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Offerte naar Moneybird", systemImage: "arrow.up.doc")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.lines.isEmpty || isExportingToMoneybird)

                Button {
                    exportToMoneybird(asInvoice: true)
                } label: {
                    if isExportingToMoneybird {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Factuur naar Moneybird", systemImage: "doc.text.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.lines.isEmpty || isExportingToMoneybird)

                Button {
                    showMoneybirdSettings = true
                } label: {
                    Label("Moneybird-instellingen", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }

            Section {
                Button(role: .destructive) {
                    store.clear()
                    discountMode = .none
                    discountPercentage = 0
                    discountFixedAmount = 0
                } label: {
                    Label("Wis aanvraag", systemImage: "trash")
                }
                .disabled(store.lines.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
        .listSectionSpacing(.compact)
        .withKeyboardDismiss()
        .navigationTitle("Aanvraag")
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
