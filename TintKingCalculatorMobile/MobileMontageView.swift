import SwiftUI
import UIKit

/// Rij in de projectenlijst, met naam, laatste wijziging en richtprijs.
private struct MobileProjectRow: View {
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

private struct MobileSettingsSheet: View {
    @Binding var settings: CalculatorSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Tarieven") {
                    MobileCurrencyField(title: "Uurtarief werk", value: $settings.hourlyRate)
                    MobileCurrencyField(title: "Reistijd per uur", value: $settings.travelHourlyRate)
                    MobileCurrencyField(title: "Kilometertarief", value: $settings.kmRate)
                    MobilePercentageField(title: "Spoedopslag", value: $settings.rushPercentage)
                }
                Section("Moeilijkheidsopslag") {
                    MobilePercentageField(title: "Normaal", value: $settings.difficultyNormalPercentage)
                    MobilePercentageField(title: "Lastig", value: $settings.difficultyHardPercentage)
                    MobilePercentageField(title: "Zeer lastig", value: $settings.difficultyVeryHardPercentage)
                }
                Section("Risico-opslag") {
                    MobilePercentageField(title: "Laag", value: $settings.riskLowPercentage)
                    MobilePercentageField(title: "Normaal", value: $settings.riskNormalPercentage)
                    MobilePercentageField(title: "Hoog", value: $settings.riskHighPercentage)
                }
            }
            .withKeyboardDismiss()
            .navigationTitle("Instellingen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gereed") { dismiss() }
                }
            }
        }
    }
}

/// Mobiele versie van het projectenoverzicht van de Offerte/montage-calculator.
struct MobileMontageView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var customerStore: CustomerStore
    @State private var searchText = ""

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

    private var filteredProjects: [SavedProject] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return store.projects
        }
        return store.projects.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func deleteProjects(at offsets: IndexSet) {
        for index in offsets {
            store.delete(projectID: filteredProjects[index].id)
        }
    }

    var body: some View {
        List {
            if filteredProjects.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "Nog geen projecten" : "Geen resultaten",
                    systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Maak een nieuwe calculatie en tik op Opslaan." : "Probeer een andere zoekterm.")
                )
            } else {
                ForEach(filteredProjects) { project in
                    NavigationLink {
                        MobileMontageEditorView(store: store, projectID: project.id, moneybirdSettings: moneybirdSettings, customerStore: customerStore)
                    } label: {
                        MobileProjectRow(project: project, currency: currency)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.delete(projectID: project.id)
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                        Button {
                            _ = store.duplicate(projectID: project.id)
                        } label: {
                            Label("Dupliceer", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            _ = store.duplicate(projectID: project.id)
                        } label: {
                            Label("Dupliceer", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            store.delete(projectID: project.id)
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteProjects)
            }
        }
        .searchable(text: $searchText, prompt: "Zoek klant of project")
        .withKeyboardDismiss()
        .navigationTitle("Offerte / montage")
        .onAppear {
            // Haalt bij het openen van dit tabblad eerst de laatste stand op —
            // zodat een wijziging die op de Mac (of elders) is opgeslagen hier
            // ook verschijnt zonder dat er handmatig op het synchroniseer-
            // knopje gedrukt hoeft te worden.
            Task { await store.syncWithCloud() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            ToolbarItem {
                NavigationLink {
                    MobileMontageEditorView(store: store, projectID: nil, moneybirdSettings: moneybirdSettings, customerStore: customerStore)
                } label: {
                    Label("Nieuw", systemImage: "plus")
                }
            }
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
    }
}

/// Mobiele versie van de invoer- en resultaatschermen van de Offerte/montage-calculator,
/// hier op één doorlopend scherm in plaats van drie kolommen naast elkaar.
struct MobileMontageEditorView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var customerStore: CustomerStore
    @State private var projectID: UUID?
    @State private var input: CalculationInput
    @State private var settings: CalculatorSettings
    @State private var showSettings = false
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

    init(store: ProjectStore, projectID: UUID?, moneybirdSettings: MoneybirdSettingsStore, customerStore: CustomerStore) {
        self.store = store
        self.moneybirdSettings = moneybirdSettings
        self.customerStore = customerStore
        _projectID = State(initialValue: projectID)
        if let projectID, let project = store.project(id: projectID) {
            _input = State(initialValue: project.input)
            _settings = State(initialValue: project.settings)
        } else {
            _input = State(initialValue: CalculationInput())
            _settings = State(initialValue: CalculatorSettings())
        }
    }

    private var currency: FloatingPointFormatStyle<Double>.Currency { mobileCurrency }

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

    // Montage wordt vrijwel altijd zakelijk gebruikt, dus de regels in de
    // offertetekst/WhatsApp/Moneybird-export staan hier — anders dan bij de
    // klantgerichte calculators (Tinten, Ontchromen, enz.) — bewust excl. btw
    // in plaats van incl. btw; de btw komt alleen nog terug in de laatste
    // drie regels van de opbouw (excl. → btw → incl.).
    private var simpleLineItems: [QuoteItem] {
        let title = input.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Montagewerk op locatie" : input.projectName
        var items = [QuoteItem(name: title, price: montagePriceBeforeDiscountExclVAT)]
        if montageDiscountExclVAT > 0 {
            items.append(QuoteItem(name: "Korting", price: -montageDiscountExclVAT))
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
        var items = detailedLineItemsExclVAT.map { QuoteItem(name: $0.name, price: $0.amount) }
        if montageDiscountExclVAT > 0 {
            items.append(QuoteItem(name: "Korting", price: -montageDiscountExclVAT))
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
            total: montageFinalInclVAT,
            itemsExcludeVAT: true
        )
    }

    /// Alleen omschrijving + bedrag per regel, voor de Moneybird-export.
    /// Geen klant- of btw-logica hier: dat doet Robin zelf na in Moneybird.
    private var moneybirdLines: [MoneybirdExportService.EstimateLine] {
        // De prijzen in lineItems staan hier (Montage) al excl. btw. Moneybird
        // telt zelf automatisch 21% btw op bij een regel, dus niet nogmaals
        // converteren — anders wordt de btw dubbel gerekend.
        lineItems.map { MoneybirdExportService.EstimateLine(description: $0.name, price: $0.price) }
    }

    private var linkedCustomer: Customer? {
        guard let linkedCustomerID = input.linkedCustomerID else { return nil }
        return customerStore.customers.first { $0.id == linkedCustomerID }
    }

    private var linkedContactId: String? {
        linkedCustomer?.moneybirdContact?.id
    }

    private var exportTargetName: String {
        linkedCustomer?.name.isEmpty == false ? linkedCustomer!.name : "App klant"
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
                    tab: .montage,
                    customerID: linkedCustomer?.id
                )
            } catch {
                moneybirdResultMessage = error.localizedDescription
                moneybirdExportSucceeded = false
            }
            isExportingToMoneybird = false
            showMoneybirdResult = true
        }
    }

    private var whatsAppQuoteText: String {
        var lines = lineItems.map { "\($0.name): \($0.price.formatted(currency))" }
        lines.append("Subtotaal excl. btw: \(montageFinalExclVAT.formatted(currency))")
        lines.append("Btw (21%): \((montageFinalInclVAT - montageFinalExclVAT).formatted(currency))")
        lines.append("Totaal incl. btw: \(montageFinalInclVAT.formatted(currency))")
        return lines.joined(separator: "\n")
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

    private func saveCurrentProject() {
        projectID = store.save(input: input, settings: settings, projectID: projectID)
        withAnimation { saveFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { saveFlash = false }
        }
    }

    @ViewBuilder
    private func breakdownRow(_ title: String, _ value: Double, bold: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(value, format: currency).fontWeight(bold ? .semibold : .regular)
        }
    }

    var body: some View {
        List {
            Section("Project") {
                TextField("Klant / project / omschrijving", text: $input.projectName)
                LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $input.linkedCustomerID)
                if let selectedProject = store.project(id: projectID) {
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
                                text: Binding(get: { input.materials[index].name }, set: { input.materials[index].name = $0 })
                            )
                            Button(role: .destructive) {
                                removeMaterialLine(id: lineID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack {
                            MobileCurrencyField(
                                title: "Inkoop",
                                value: Binding(get: { input.materials[index].cost }, set: { input.materials[index].cost = $0 })
                            )
                        }
                        HStack {
                            MobilePercentageField(
                                title: "Opslag",
                                value: Binding(get: { input.materials[index].markup }, set: { input.materials[index].markup = $0 })
                            )
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Doorberekend").font(.caption).foregroundStyle(.secondary)
                                Text(input.materials[index].charged, format: currency).fontWeight(.semibold)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    addMaterialLine()
                } label: {
                    Label("Inkoopregel toevoegen", systemImage: "plus.circle.fill")
                }

                LabeledContent("Totale inkoop") {
                    Text(result.materialCost, format: currency).fontWeight(.semibold)
                }
                LabeledContent("Doorberekend materiaal") {
                    Text(result.materialCharged, format: currency).fontWeight(.semibold)
                }
                LabeledContent("Materiaalopbrengst") {
                    Text(result.materialCharged - result.materialCost, format: currency).fontWeight(.semibold)
                }

                MobileCurrencyField(title: "Verzend-/orderkosten", value: $input.shipping)
            }

            Section("Tijd en montage") {
                MobileNumberField(title: "Voorbereiding werkplaats", suffix: "uur", value: $input.prepHours)
                MobileNumberField(title: "Montage op locatie", suffix: "uur", value: $input.installHours)
                Stepper("Aantal personen: \(input.installers)", value: $input.installers, in: 1...10)
                MobileNumberField(title: "Reistijd totaal", suffix: "uur", value: $input.travelHours)
                MobileNumberField(title: "Kilometers totaal", suffix: "km", value: $input.kilometers)
            }

            Section("Overige kosten") {
                MobileCurrencyField(title: "Parkeren / tol", value: $input.parkingToll)
                MobileCurrencyField(title: "Hoogwerker / steiger / huur", value: $input.rental)
                MobileCurrencyField(title: "Overige directe kosten", value: $input.otherDirectCosts)
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
                MobileCurrencyField(title: "Gekozen verkoopprijs excl. btw", value: $input.chosenPrice)
            }

            Section("Korting") {
                MobileDiscountSection(mode: $discountMode, percentage: $discountPercentage, fixedAmount: $discountFixedAmount)
            }

            Section("Berekende richtprijs") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.suggestedPrice, format: currency)
                                .font(.system(size: 32, weight: .bold))
                            Text("excl. btw").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(includingVAT(fromExcludingVAT: result.suggestedPrice), format: currency)
                                .font(.title3.bold())
                            Text("incl. btw").foregroundStyle(.secondary)
                        }
                    }

                    if montageDiscountExclVAT > 0 {
                        Divider()
                        LabeledContent("Korting excl. btw") { Text(-montageDiscountExclVAT, format: currency) }
                        LabeledContent("Na korting excl. btw") { Text(montageFinalExclVAT, format: currency).fontWeight(.bold) }
                        LabeledContent("Na korting incl. btw") { Text(montageFinalInclVAT, format: currency).fontWeight(.bold) }
                    }

                    HStack(spacing: 16) {
                        MobileMetric(title: "Inkoop materiaal", value: result.materialCost.formatted(currency))
                        MobileMetric(title: "Na directe kosten", value: result.amountAfterDirectCosts.formatted(currency))
                    }
                    MobileMetric(title: "Effectief / gewerkt uur", value: result.effectivePerWorkedHour.formatted(currency))

                    if input.chosenPrice > 0 {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gekozen prijs: \(input.chosenPrice.formatted(currency)) excl. btw")
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
                .padding(.vertical, 4)
            }

            Section("Opbouw") {
                breakdownRow("Materialen incl. opslag", result.materialCharged)
                breakdownRow("Voorbereiding", result.prepLabor)
                breakdownRow("Montage (\(result.installHoursTotal.formatted(.number.precision(.fractionLength(1)))) uur)", result.installLabor)
                breakdownRow("Reistijd", result.travelCharge)
                breakdownRow("Kilometers", result.kmCharge)
                breakdownRow("Overige directe kosten", result.directExtras)
                breakdownRow("Subtotaal", result.subtotal, bold: true)
                HStack {
                    Text("Moeilijkheid")
                    Spacer()
                    Text("× \(input.difficulty.factor(in: settings).formatted(.number.precision(.fractionLength(2))))")
                }
                HStack {
                    Text("Risico-opslag")
                    Spacer()
                    Text(input.risk.percentage(in: settings), format: .percent)
                }
                if input.rush {
                    HStack {
                        Text("Spoedopslag")
                        Spacer()
                        Text(settings.rushPercentage, format: .percent)
                    }
                }
            }

            Section("Offertetekst") {
                Toggle("Uitgesplitst (materialen, uren, hoogwerker, enz.)", isOn: $showDetailedBreakdown)

                Text(quoteText)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.vertical, 4)

                Button {
                    if let phone = linkedCustomer?.whatsAppPhone, let url = WhatsAppLink.url(phone: phone, message: whatsAppQuoteText) {
                        UIApplication.shared.open(url)
                    } else {
                        UIPasteboard.general.string = whatsAppQuoteText
                    }
                } label: {
                    Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    UIPasteboard.general.string = quoteText
                } label: {
                    Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

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
                .disabled(isExportingToMoneybird)

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
                .disabled(isExportingToMoneybird)

                Button {
                    showMoneybirdSettings = true
                } label: {
                    Label("Moneybird-instellingen", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 36)
        .listSectionSpacing(.compact)
        .withKeyboardDismiss()
        .navigationTitle(input.projectName.isEmpty ? "Nieuwe calculatie" : input.projectName)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                Button {
                    saveCurrentProject()
                } label: {
                    Label(saveFlash ? "Opgeslagen" : "Opslaan", systemImage: saveFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            MobileSettingsSheet(settings: $settings)
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
