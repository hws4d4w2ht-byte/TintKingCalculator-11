import SwiftUI
import AppKit

struct MontageCalculatorView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var customerStore: CustomerStore
    /// Extern verzoek (bijv. vanuit Klanten → Geschiedenis) om een specifiek
    /// project te openen — wordt na het overnemen meteen weer op nil gezet.
    @Binding var selectedMontageProjectID: UUID?
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
            .onChange(of: selectedMontageProjectID) { _, newValue in
                // Rechtstreeks input/settings overnemen i.p.v. alleen
                // selectedProjectID te zetten en te wachten tot de andere
                // onChange hierboven dat oppikt — dat gaf in de praktijk een
                // tabwissel zonder dat het project ook echt geladen werd.
                guard let newValue, let project = store.project(id: newValue) else { return }
                selectedProjectID = newValue
                input = project.input
                settings = project.settings
                selectedMontageProjectID = nil
            }
            .onAppear {
                // Haalt bij het openen van dit scherm eerst de laatste stand op —
                // zodat een wijziging die op de telefoon (of Mac elders) is
                // opgeslagen hier ook verschijnt zonder dat er handmatig op het
                // synchroniseer-knopje gedrukt hoeft te worden.
                Task { await store.syncWithCloud() }
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

    private var whatsAppQuoteText: String {
        var lines = lineItems.map { "\($0.name): \($0.price.formatted(currency))" }
        lines.append("Subtotaal excl. btw: \(montageFinalExclVAT.formatted(currency))")
        lines.append("Btw (21%): \((montageFinalInclVAT - montageFinalExclVAT).formatted(currency))")
        lines.append("Totaal incl. btw: \(montageFinalInclVAT.formatted(currency))")
        return lines.joined(separator: "\n")
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

    private var quoteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Toon uitgesplitst (materialen, uren, hoogwerker, enz.)", isOn: $showDetailedBreakdown)
                .toggleStyle(.switch)

            LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $input.linkedCustomerID)

            HStack {
                Text("Offertetekst").font(.title2.bold())
                Spacer()
                Button {
                    if let phone = linkedCustomer?.whatsAppPhone, let url = WhatsAppLink.url(phone: phone, message: whatsAppQuoteText) {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(whatsAppQuoteText, forType: .string)
                    }
                } label: {
                    Label("WhatsApp", systemImage: "message.fill")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quoteText, forType: .string)
                } label: {
                    Label("E-mail", systemImage: "envelope.fill")
                }
                Menu {
                    Button {
                        exportToMoneybird(asInvoice: false)
                    } label: {
                        Label("Als offerte", systemImage: "doc.text")
                    }
                    Button {
                        exportToMoneybird(asInvoice: true)
                    } label: {
                        Label("Als factuur", systemImage: "doc.text.fill")
                    }
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
                .font(.system(.body, design: .monospaced))
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

struct ProjectRow: View {
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

struct Metric: View {
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

struct CurrencyField: View {
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

struct NumberField: View {
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

struct PercentageField: View {
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

struct SettingsView: View {
    @Binding var settings: CalculatorSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Instellingen").font(.title.bold())
            Form {
                Section("Tarieven") {
                    CurrencyField(title: "Uurtarief werk", value: $settings.hourlyRate)
                    CurrencyField(title: "Reistijd per uur", value: $settings.travelHourlyRate)
                    CurrencyField(title: "Kilometertarief", value: $settings.kmRate)
                    PercentageField(title: "Spoedopslag", value: $settings.rushPercentage)
                }
                Section("Moeilijkheidsopslag") {
                    PercentageField(title: "Normaal", value: $settings.difficultyNormalPercentage)
                    PercentageField(title: "Lastig", value: $settings.difficultyHardPercentage)
                    PercentageField(title: "Zeer lastig", value: $settings.difficultyVeryHardPercentage)
                }
                Section("Risico-opslag") {
                    PercentageField(title: "Laag", value: $settings.riskLowPercentage)
                    PercentageField(title: "Normaal", value: $settings.riskNormalPercentage)
                    PercentageField(title: "Hoog", value: $settings.riskHighPercentage)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Gereed") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 560)
    }
}
