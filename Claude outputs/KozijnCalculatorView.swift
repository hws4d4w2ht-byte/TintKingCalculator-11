import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Calculator voor het wrappen van kozijnen (ramen en deuren) met folie.
/// Je geeft eerst het type (raam of deur) en de buitenmaten van het kozijn
/// op, met eventueel een draairaam (met zijn eigen, los in te vullen maten
/// en positie) of een verticaal middenstuk (ook met een eigen positie) —
/// daarna zie je een schematische voorbeeldweergave. Op basis daarvan
/// worden de te knippen stroken voorgesteld; de breedte van de folie (voor
/// het knippen van rolletjes) en de lengtes vul je daarna zelf in of pas
/// je aan, en per onderdeel kun je een extra strook toevoegen als dat
/// onderdeel uit meerdere stroken folie bestaat. Komt een kozijn vaker
/// voor, dan vul je gewoon het aantal in. Er wordt geen prijs berekend —
/// het gaat om de benodigde lengtes per foliebreedte.
struct KozijnCalculatorView: View {
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @StateObject private var projectStore = KozijnProjectStore()

    @State private var kozijnen: [KozijnItem] = []
    @State private var kozijnPendingDeletion: KozijnItem?
    @State private var pdfDocument: KozijnenPDFDocument?
    @State private var isExportingPDF = false
    @State private var linkedCustomerID: UUID?

    // MARK: - Projecten (opslaan/laden)
    @State private var projectName: String = ""
    @State private var selectedProjectID: UUID?
    @State private var projectSearchText: String = ""
    @State private var saveFlash = false
    #if os(iOS)
    @State private var isPresentingProjectList = false
    #endif

    // MARK: - Moneybird
    /// Prijs per strekkende meter folie (excl. btw) — instelbaar, standaard
    /// € 18, en onthouden voor de volgende keer.
    @AppStorage("KozijnCalculator.pricePerMeter") private var pricePerMeter: Double = 18
    @State private var isExportingToMoneybird = false
    @State private var moneybirdResultMessage: String?
    @State private var moneybirdExportSucceeded = false
    @State private var showMoneybirdResult = false
    @State private var showMoneybirdSettings = false

    private var linkedCustomer: Customer? {
        guard let linkedCustomerID else { return nil }
        return customerStore.customers.first { $0.id == linkedCustomerID }
    }

    private var linkedContactId: String? {
        linkedCustomer?.moneybirdContact?.id
    }

    private var exportTargetName: String {
        (linkedCustomer?.name.isEmpty == false) ? linkedCustomer!.name : "App klant"
    }

    private var currencyFormat: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    /// Totaalbedrag (excl. btw): totaal aantal strekkende meters folie ×
    /// prijs per strekkende meter.
    private var invoiceAmount: Double {
        (grandTotalCm / 100) * pricePerMeter
    }

    /// Alleen omschrijving + bedrag, voor de Moneybird-export. Eén regel voor
    /// de hele klus (net als bij de andere calculators laat je btw en
    /// grootboekrekening leeg — dat vult Moneybird zelf aan, en jij
    /// controleert het na).
    private var moneybirdDescription: String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "Kozijn wrappen" : "Kozijn wrappen — \(name)"
        let count = kozijnen.count
        let suffix = count == 1 ? "1 kozijn" : "\(count) kozijnen"
        return "\(base) (\(suffix))"
    }

    private var moneybirdLines: [MoneybirdExportService.EstimateLine] {
        [MoneybirdExportService.EstimateLine(description: moneybirdDescription, price: invoiceAmount)]
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
                    tab: .kozijn,
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

    private var filteredProjects: [KozijnProject] {
        let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectStore.projects }
        return projectStore.projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private func newProject() {
        kozijnen = []
        linkedCustomerID = nil
        projectName = ""
        selectedProjectID = nil
    }

    private func loadProject(_ project: KozijnProject) {
        kozijnen = project.kozijnen
        linkedCustomerID = project.linkedCustomerID
        projectName = project.name
        selectedProjectID = project.id
    }

    private func saveCurrentProject() {
        let finalName = projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Naamloos project"
            : projectName
        selectedProjectID = projectStore.save(
            name: finalName,
            kozijnen: kozijnen,
            linkedCustomerID: linkedCustomerID,
            projectID: selectedProjectID
        )
        projectName = finalName
        withAnimation { saveFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { saveFlash = false }
        }
    }

    private func duplicateProject(_ id: UUID) {
        guard let newID = projectStore.duplicate(projectID: id), let project = projectStore.project(id: newID) else { return }
        loadProject(project)
    }

    private func deleteProject(_ id: UUID) {
        projectStore.delete(projectID: id)
        if selectedProjectID == id {
            newProject()
        }
    }

    private var lengthByFoilWidth: [(width: Double, totalCm: Double)] {
        var totals: [Double: Double] = [:]
        for kozijn in kozijnen {
            let qty = Double(kozijn.quantity)
            for part in kozijn.parts where part.foilWidthCm > 0 {
                totals[part.foilWidthCm, default: 0] += part.lengthCm * qty
            }
        }
        return totals.keys.sorted().map { (width: $0, totalCm: totals[$0] ?? 0) }
    }

    /// Per foliebreedte alle losse strooklengtes apart (al vermenigvuldigd
    /// met het aantal identieke kozijnen). Een strook plak je altijd uit één
    /// stuk — nooit uit meerdere delen aan elkaar — dus voor de rolberekening
    /// moet elke strook in zijn geheel op één baan passen. Dat is iets heel
    /// anders dan alleen het totaal aantal meters van die breedte, en bepaalt
    /// hoe ver je per baan minimaal moet doorrollen.
    private var stripLengthsByFoilWidth: [Double: [Double]] {
        var groups: [Double: [Double]] = [:]
        for kozijn in kozijnen {
            let qty = max(kozijn.quantity, 0)
            for part in kozijn.parts where part.foilWidthCm > 0 && part.lengthCm > 0 {
                groups[part.foilWidthCm, default: []].append(contentsOf: Array(repeating: part.lengthCm, count: qty))
            }
        }
        return groups
    }

    /// Verdeelt een set losse strooklengtes zo eerlijk mogelijk over een
    /// gegeven aantal banen (longest-processing-time: begin met de langste
    /// strook en leg 'm steeds op de baan die op dat moment het minst gevuld
    /// is — nooit een strook opknippen) en geeft de lengte terug van de baan
    /// die daarna het verst moet doorrollen. Dat, en niet het simpele
    /// gemiddelde, bepaalt hoeveel er van de rol af moet voor die breedte.
    private func bottleneckLength(for lengths: [Double], lanes: Int) -> Double {
        guard lanes > 0, !lengths.isEmpty else { return 0 }
        var bins = [Double](repeating: 0, count: lanes)
        for length in lengths.sorted(by: >) {
            guard let minIndex = bins.indices.min(by: { bins[$0] < bins[$1] }) else { continue }
            bins[minIndex] += length
        }
        return bins.max() ?? 0
    }

    private var grandTotalCm: Double {
        kozijnen.reduce(0) { partial, kozijn in
            partial + kozijn.parts.reduce(0) { $0 + $1.lengthCm } * Double(kozijn.quantity)
        }
    }

    /// Totaal aantal fysieke stroken dat geknipt moet worden (over alle
    /// kozijnen en hun aantallen heen) — voor de rolberekening hieronder.
    private var totalStripCount: Int {
        kozijnen.reduce(0) { $0 + $1.parts.count * $1.quantity }
    }

    /// De kozijnfolie is een vast product van 120 cm breed. Van een
    /// foliebreedte die veel meters nodig heeft, snijd je meteen meerdere
    /// banen tegelijk naast elkaar — zo krijg je per afgerolde meter meteen
    /// meerdere meters van die breedte, en hoef je minder van de rol af te
    /// rollen. De rollengte is meestal 50 m, maar bijvoorbeeld bij een
    /// restrol kan dat minder zijn — vandaar hieronder instelbaar.
    private static let rollWidthCm: Double = 120
    @State private var rollLengthM: Double = 50

    /// De ingevulde rollengte, veilig begrensd tussen 1 en 50 m.
    private var effectiveRollLengthM: Double {
        min(max(rollLengthM, 1), 50)
    }

    /// Verdeelt de 120 cm rolbreedte over de gebruikte foliebreedtes: elke
    /// breedte begint met één baan. Zolang de stroken van een breedte (als
    /// hele stukken, via bottleneckLength) niet binnen de ingevulde
    /// rollengte passen, krijgt die breedte er een baan bij — net zo lang
    /// tot het wél past, of tot de rolbreedte op is. Het doel is dus niet om
    /// de rolbreedte tot de laatste cm te vullen, maar om met zo min
    /// mogelijk banen (een zo simpel mogelijk snijplan) toch binnen één
    /// rollengte te blijven; extra banen komen er alleen bij als dat
    /// daadwerkelijk nodig is. Past een breedte ook met alle beschikbare
    /// rolbreedte niet binnen de rollengte, dan blijkt dat verderop uit een
    /// hoger "Rollen nodig" — dan is er gewoon meer folie nodig, geen extra
    /// baan die dat oplost.
    private var laneAllocation: [(width: Double, lanes: Int, totalCm: Double)] {
        let strips = stripLengthsByFoilWidth
        let entries = lengthByFoilWidth.filter { $0.totalCm > 0 }
        guard !entries.isEmpty else { return [] }

        let targetLengthCm = effectiveRollLengthM * 100

        var lanes: [Double: Int] = Dictionary(uniqueKeysWithValues: entries.map { ($0.width, 1) })
        var usedWidth = entries.reduce(0) { $0 + $1.width }

        while true {
            let remaining = Self.rollWidthCm - usedWidth

            var worstWidth: Double?
            var worstCurrent = targetLengthCm
            for entry in entries where entry.width <= remaining {
                let lengths = strips[entry.width] ?? []
                let currentLanes = lanes[entry.width] ?? 1
                let current = bottleneckLength(for: lengths, lanes: currentLanes)
                guard current > targetLengthCm else { continue }
                let next = bottleneckLength(for: lengths, lanes: currentLanes + 1)
                guard next < current - 0.01, current > worstCurrent else { continue }
                worstWidth = entry.width
                worstCurrent = current
            }

            guard let width = worstWidth else { break }
            lanes[width, default: 1] += 1
            usedWidth += width
        }

        return entries.map { (width: $0.width, lanes: lanes[$0.width] ?? 1, totalCm: $0.totalCm) }
    }

    /// Hoeveel van de 120 cm rolbreedte er in totaal gebruikt wordt met de
    /// verdeling hierboven — zo zie je hoe vol de rol benut wordt.
    private var usedRollWidthCm: Double {
        laneAllocation.reduce(0) { $0 + $1.width * Double($1.lanes) }
    }

    private var remainingRollWidthCm: Double {
        Self.rollWidthCm - usedRollWidthCm
    }

    /// Benodigde rollengte in cm: per breedte de baan die (met de losse
    /// stroken als hele stukken verdeeld) het verst moet doorrollen, en
    /// daarvan de langste over alle breedtes — dat bepaalt hoeveel er
    /// minimaal van de rol afgerold moet worden.
    private var rollLengthNeededCm: Double {
        let strips = stripLengthsByFoilWidth
        return laneAllocation
            .map { bottleneckLength(for: strips[$0.width] ?? [], lanes: $0.lanes) }
            .max() ?? 0
    }

    /// Aantal rollen dat nodig is om een bepaalde lengte (in cm) af te
    /// wikkelen, gegeven de ingevulde rollengte.
    private func rollsNeeded(forCm cm: Double) -> Int {
        let metersNeeded = cm / 100
        guard metersNeeded > 0 else { return 0 }
        return Int((metersNeeded / effectiveRollLengthM).rounded(.up))
    }

    private var rollsNeeded: Int {
        rollsNeeded(forCm: rollLengthNeededCm)
    }

    private var cutListText: String {
        var lines: [String] = []
        for kozijn in kozijnen where !kozijn.parts.isEmpty {
            let suffix = kozijn.quantity > 1 ? " (× \(kozijn.quantity))" : ""
            lines.append("\(kozijn.displayLabel)\(suffix):")
            for part in kozijn.parts {
                let widthText = part.foilWidthCm > 0 ? "\(formattedCm(part.foilWidthCm)) cm breed" : "breedte nog invullen"
                lines.append("- \(part.label): \(formattedCm(part.lengthCm)) cm (\(widthText))")
            }
            lines.append("")
        }
        if !lengthByFoilWidth.isEmpty {
            lines.append("Totaal per foliebreedte:")
            for entry in lengthByFoilWidth {
                lines.append("- \(formattedCm(entry.width)) cm breed: \(formattedMeters(entry.totalCm)) m")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formattedCm(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
    private func formattedMeters(_ cm: Double) -> String {
        (cm / 100).formatted(.number.precision(.fractionLength(0...2)))
    }

    #if os(iOS)
    private let cardSpacing: CGFloat = 8
    private let cardPadding: CGFloat = 10
    private let sectionSpacing: CGFloat = 8
    private let measurementSpacing: CGFloat = 10
    #else
    private let cardSpacing: CGFloat = 10
    private let cardPadding: CGFloat = 12
    private let sectionSpacing: CGFloat = 12
    private let measurementSpacing: CGFloat = 16
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            mainContent
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            saveCurrentProject()
                        } label: {
                            Label(saveFlash ? "Opgeslagen" : "Opslaan", systemImage: saveFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
                        }
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }
        }
        #else
        mainContent
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isPresentingProjectList = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    Button {
                        saveCurrentProject()
                    } label: {
                        Image(systemName: saveFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $isPresentingProjectList) {
                NavigationStack {
                    projectListSheet
                }
            }
        #endif
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                header

                projectNameField

                LinkedCustomerPicker(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $linkedCustomerID)

                if kozijnen.isEmpty {
                    ContentUnavailableView(
                        "Nog geen kozijnen",
                        systemImage: "square.dashed",
                        description: Text("Voeg hierboven een kozijn toe en vul de maten in.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ForEach($kozijnen) { $kozijn in
                        kozijnCard($kozijn)
                    }
                }

                if !kozijnen.isEmpty {
                    summaryCard
                    rollCard
                    moneybirdCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Kozijn wrappen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Kozijn verwijderen?",
            isPresented: Binding(
                get: { kozijnPendingDeletion != nil },
                set: { if !$0 { kozijnPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Verwijderen", role: .destructive) {
                if let target = kozijnPendingDeletion {
                    kozijnen.removeAll { $0.id == target.id }
                }
                kozijnPendingDeletion = nil
            }
            Button("Annuleren", role: .cancel) {
                kozijnPendingDeletion = nil
            }
        }
        .fileExporter(
            isPresented: $isExportingPDF,
            document: pdfDocument,
            contentType: .pdf,
            defaultFilename: "Kozijnen"
        ) { _ in }
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kozijn wrappen")
                    #if os(iOS)
                    .font(.headline)
                    #else
                    .font(.title2.bold())
                    #endif
                Text("Vul de maten in, bekijk het voorbeeld en genereer de stroken. Vul daarna per strook de foliebreedte in.")
                    #if os(iOS)
                    .font(.caption2)
                    #else
                    .font(.footnote)
                    #endif
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                kozijnen.append(KozijnItem())
            } label: {
                Label("Nieuw kozijn", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            #if os(iOS)
            .controlSize(.small)
            #endif
        }
    }

    /// Naam van het huidige project, alleen nodig om het straks terug te
    /// kunnen vinden in de opgeslagen projecten — hoeft verder niet ingevuld
    /// te worden om gewoon te kunnen rekenen.
    private var projectNameField: some View {
        HStack(spacing: 8) {
            Text("Project")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Naam (optioneel)", text: $projectName)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .font(.subheadline)
                #endif
        }
    }

    #if os(macOS)
    private var projectSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProjectID) {
                Section("Opgeslagen projecten") {
                    if filteredProjects.isEmpty {
                        ContentUnavailableView(
                            projectSearchText.isEmpty ? "Nog geen projecten" : "Geen resultaten",
                            systemImage: projectSearchText.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(projectSearchText.isEmpty ? "Maak kozijnen aan en klik op Opslaan." : "Probeer een andere zoekterm.")
                        )
                    } else {
                        ForEach(filteredProjects) { project in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayName)
                                Text(projectSubtitle(project))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(project.id)
                            .contextMenu {
                                Button("Dupliceren") { duplicateProject(project.id) }
                                Divider()
                                Button("Verwijderen", role: .destructive) { deleteProject(project.id) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $projectSearchText, prompt: "Zoek project")
            .onChange(of: selectedProjectID) { _, newValue in
                guard let id = newValue, let project = projectStore.project(id: id) else { return }
                loadProject(project)
            }

            Divider()

            HStack {
                Button {
                    newProject()
                } label: {
                    Label("Nieuw", systemImage: "plus")
                }

                Spacer()

                if let selectedProjectID {
                    Menu {
                        Button("Dupliceren") { duplicateProject(selectedProjectID) }
                        Button("Verwijderen", role: .destructive) { deleteProject(selectedProjectID) }
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
    #else
    private var projectListSheet: some View {
        List {
            Section {
                Button {
                    newProject()
                    isPresentingProjectList = false
                } label: {
                    Label("Nieuw project", systemImage: "plus")
                }
            }
            Section("Opgeslagen projecten") {
                if projectStore.projects.isEmpty {
                    Text("Nog geen projecten opgeslagen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projectStore.projects) { project in
                        Button {
                            loadProject(project)
                            isPresentingProjectList = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.displayName)
                                        .foregroundStyle(.primary)
                                    Text(projectSubtitle(project))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if project.id == selectedProjectID {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            deleteProject(projectStore.projects[index].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Projecten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Sluiten") { isPresentingProjectList = false }
            }
        }
    }
    #endif

    private func projectSubtitle(_ project: KozijnProject) -> String {
        let count = project.kozijnen.count
        let kozijnText = count == 1 ? "1 kozijn" : "\(count) kozijnen"
        return "\(kozijnText) · \(project.modifiedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func kozijnCard(_ kozijn: Binding<KozijnItem>) -> some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            HStack {
                TextField("Naam (optioneel)", text: kozijn.label)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .font(.subheadline)
                    #else
                    .frame(maxWidth: 240)
                    #endif
                #if os(macOS)
                Spacer(minLength: 8)
                #endif
                Stepper(value: kozijn.quantity, in: 1...99) {
                    Text("×\(kozijn.wrappedValue.quantity)")
                        .font(.caption)
                }
                .fixedSize()
                Button(role: .destructive) {
                    kozijnPendingDeletion = kozijn.wrappedValue
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Picker("Type kozijn", selection: kozijn.frameType) {
                ForEach(KozijnFrameType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)

            if kozijn.wrappedValue.frameType == .windowsill {
                Text("Een vensterbank heeft geen kozijn-opening — vul alleen de lengte in.")
                    #if os(iOS)
                    .font(.caption2)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.secondary)
                measurementField(title: "Lengte (cm)", value: kozijn.windowsillLengthCm)
            } else {
                HStack(spacing: measurementSpacing) {
                    measurementField(title: "Breedte (cm)", value: kozijn.widthCm)
                    measurementField(title: "Hoogte (cm)", value: kozijn.heightCm)
                    measurementField(title: "Profiel (cm)", value: kozijn.frameProfileCm)
                }

                Picker("Middenverdeling", selection: kozijn.middleType) {
                    ForEach(KozijnMiddleType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if kozijn.wrappedValue.middleType == .casement {
                    Text("Maten van het draairaam zelf (kan kleiner zijn dan het kozijn):")
                        #if os(iOS)
                        .font(.caption2)
                        #else
                        .font(.caption)
                        #endif
                        .foregroundStyle(.secondary)
                    HStack(spacing: measurementSpacing) {
                        measurementField(title: "Breedte draairaam (cm)", value: kozijn.casementWidthCm)
                        measurementField(title: "Hoogte draairaam (cm)", value: kozijn.casementHeightCm)
                        measurementField(title: "Profiel draairaam (cm)", value: kozijn.secondaryProfileCm)
                    }
                    Picker("Positie draairaam", selection: kozijn.casementHorizontalPosition) {
                        ForEach(KozijnHorizontalPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                } else if kozijn.wrappedValue.middleType == .mullion {
                    measurementField(title: "Profiel middenstuk (cm)", value: kozijn.secondaryProfileCm)
                    Picker("Positie middenstuk", selection: kozijn.mullionHorizontalPosition) {
                        ForEach(KozijnHorizontalPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                KozijnPreview(
                    widthCm: kozijn.wrappedValue.widthCm,
                    heightCm: kozijn.wrappedValue.heightCm,
                    frameProfileCm: kozijn.wrappedValue.frameProfileCm,
                    frameType: kozijn.wrappedValue.frameType,
                    middleType: kozijn.wrappedValue.middleType,
                    secondaryProfileCm: kozijn.wrappedValue.secondaryProfileCm,
                    casementWidthCm: kozijn.wrappedValue.casementWidthCm,
                    casementHeightCm: kozijn.wrappedValue.casementHeightCm,
                    casementHorizontalPosition: kozijn.wrappedValue.casementHorizontalPosition,
                    mullionHorizontalPosition: kozijn.wrappedValue.mullionHorizontalPosition
                )
            }

            Button {
                kozijn.wrappedValue.parts = kozijn.wrappedValue.generatedParts()
            } label: {
                Label("Genereer stroken uit maten", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            #if os(iOS)
            .controlSize(.small)
            #endif

            if !kozijn.wrappedValue.parts.isEmpty {
                Divider()
                ForEach(kozijn.parts) { $part in
                    partRow($part, kozijn: kozijn)
                }

                let singleTotal = kozijn.wrappedValue.parts.reduce(0) { $0 + $1.lengthCm }
                let kozijnTotal = singleTotal * Double(kozijn.wrappedValue.quantity)
                HStack {
                    Text(kozijn.wrappedValue.quantity > 1 ? "Totaal (× \(kozijn.wrappedValue.quantity))" : "Totaal deze kozijn")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(formattedMeters(kozijnTotal)) m")
                        .font(.subheadline.bold())
                }
            }

            Button {
                kozijn.wrappedValue.parts.append(KozijnPart())
            } label: {
                Label("Onderdeel toevoegen", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.footnote)
        }
        .padding(cardPadding)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func measurementField(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            #if os(iOS)
            Text(title.replacingOccurrences(of: " (cm)", with: ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            AppNumberField(placeholder: title, value: value, decimals: 0...1)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(width: 52)
            #else
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AppNumberField(placeholder: title, value: value, decimals: 0...1)
            #endif
        }
    }

    #if os(iOS)
    /// De naam van een strook (boven/onder/links/rechts/…) hoeft in de
    /// praktijk niet aangepast te worden, dus staat alles compact op één
    /// regel: naam, lengte, "breedte folie", foliebreedte en de knoppen.
    private func partRow(_ part: Binding<KozijnPart>, kozijn: Binding<KozijnItem>) -> some View {
        HStack(spacing: 3) {
            TextField("Onderdeel", text: part.label)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .fixedSize()

            AppNumberField(placeholder: "Lengte", value: part.lengthCm, decimals: 0...1)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .frame(width: 32)
            Text("cm")
                .font(.subheadline)

            Text("breedte folie")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            AppNumberField(placeholder: "Breedte", value: part.foilWidthCm, decimals: 0...1)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .frame(width: 32)
            Text("cm")
                .font(.subheadline)

            Spacer(minLength: 0)

            Button {
                addExtraStrip(after: part.wrappedValue, in: kozijn)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                kozijn.wrappedValue.parts.removeAll { $0.id == part.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
    #else
    private func partRow(_ part: Binding<KozijnPart>, kozijn: Binding<KozijnItem>) -> some View {
        HStack(spacing: 8) {
            TextField("Onderdeel", text: part.label)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)

            AppNumberField(placeholder: "Lengte", value: part.lengthCm, decimals: 0...1)
                .frame(width: 70)
            Text("cm lang")
                .font(.caption2)
                .foregroundStyle(.secondary)

            AppNumberField(placeholder: "Breedte folie", value: part.foilWidthCm, decimals: 0...1)
                .frame(width: 70)
            Text("cm breed")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                addExtraStrip(after: part.wrappedValue, in: kozijn)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                kozijn.wrappedValue.parts.removeAll { $0.id == part.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
    #endif

    /// Voegt, voor een kozijndeel dat uit meerdere stroken folie bestaat,
    /// direct na de bestaande strook een nieuwe strook toe met dezelfde
    /// naam en lengte — genummerd ("Boven 2", "Boven 3", …) zodat de stroken
    /// van elkaar te onderscheiden zijn. De foliebreedte vul je daarna apart in.
    private func addExtraStrip(after part: KozijnPart, in kozijn: Binding<KozijnItem>) {
        guard let index = kozijn.wrappedValue.parts.firstIndex(where: { $0.id == part.id }) else { return }
        let base = Self.baseStripLabel(part.label)
        let existingCount = kozijn.wrappedValue.parts.filter { Self.baseStripLabel($0.label) == base }.count
        var extra = KozijnPart()
        extra.label = "\(base) \(existingCount + 1)"
        extra.lengthCm = part.lengthCm
        kozijn.wrappedValue.parts.insert(extra, at: index + 1)
    }

    /// Haalt een eventueel volgnummer ("Boven 2" → "Boven") van een
    /// strooknaam af, zodat gelijksoortige stroken bij elkaar geteld worden.
    private static func baseStripLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #" \d+$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            HStack {
                Text("Totaal benodigde folie")
                    #if os(iOS)
                    .font(.subheadline.bold())
                    #else
                    .font(.headline)
                    #endif
                Spacer()
                Text("\(formattedMeters(grandTotalCm)) m")
                    #if os(iOS)
                    .font(.subheadline.bold())
                    #else
                    .font(.headline)
                    #endif
            }

            if !lengthByFoilWidth.isEmpty {
                ForEach(lengthByFoilWidth, id: \.width) { entry in
                    HStack {
                        Text("\(formattedCm(entry.width)) cm breed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formattedMeters(entry.totalCm)) m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            #if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                copyButton
                exportPDFButton
            }
            #else
            HStack(spacing: 8) {
                copyButton
                exportPDFButton
            }
            #endif
        }
        .padding(cardPadding)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Rolberekening voor de kozijnfolie: een vast product van 120 cm breed
    /// en 50 m lang. Laat zien hoeveel stroken je in totaal gebruikt, hoeveel
    /// rollengte dat kost (rekening houdend met het aantal stroken dat naast
    /// elkaar op de 120 cm brede rol past) en hoeveel rollen je nodig hebt.
    private var rollCard: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            Text("Rolberekening — kozijnfolie \(formattedCm(Self.rollWidthCm)) cm breed")
                #if os(iOS)
                .font(.caption.bold())
                #else
                .font(.subheadline.bold())
                #endif

            HStack {
                Text("Rollengte (bijv. bij een restrol)")
                    .foregroundStyle(.secondary)
                Spacer()
                AppNumberField(placeholder: "50", value: $rollLengthM, decimals: 0...1)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                Text("m")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack {
                Text("Rollen nodig")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(rollsNeeded)")
                    .bold()
            }
            .font(.caption)

            HStack {
                Text("Benodigde rollengte")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(formattedMeters(rollLengthNeededCm)) m")
            }
            .font(.caption)

            if !laneAllocation.isEmpty {
                Divider()

                Text("Snijplan — hoeveel banen van elke breedte uit de rol van \(formattedCm(Self.rollWidthCm)) cm")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(laneAllocation, id: \.width) { entry in
                    HStack {
                        Text("\(formattedCm(entry.width)) cm")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.lanes) baan\(entry.lanes == 1 ? "" : "en")")
                    }
                    .font(.caption)
                }

                HStack {
                    Text("Gebruikte breedte")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formattedCm(usedRollWidthCm)) van \(formattedCm(Self.rollWidthCm)) cm")
                }
                .font(.caption)

                HStack {
                    Text("Resterende breedte")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formattedCm(remainingRollWidthCm)) cm")
                        .foregroundStyle(remainingRollWidthCm < 0 ? .red : .primary)
                }
                .font(.caption)

                if remainingRollWidthCm < 0 {
                    Text("Let op: deze foliebreedtes passen niet allemaal naast elkaar op de rol van \(formattedCm(Self.rollWidthCm)) cm — verdeel de stroken over meerdere rollen of pas de foliebreedtes aan.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(cardPadding)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var moneybirdCard: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            Text("Moneybird")
                #if os(iOS)
                .font(.caption.bold())
                #else
                .font(.subheadline.bold())
                #endif

            HStack {
                Text("Prijs per strekkende meter (excl. btw)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("€")
                    .foregroundStyle(.secondary)
                AppNumberField(placeholder: "18", value: $pricePerMeter, decimals: 0...2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
            }
            .font(.caption)

            HStack {
                Text("Totaalbedrag (\(formattedMeters(grandTotalCm)) m × \(pricePerMeter.formatted(currencyFormat)))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(invoiceAmount.formatted(currencyFormat))
                    .bold()
            }
            .font(.caption)

            HStack {
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
                        Label("Maak offerte/factuur", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isExportingToMoneybird)
                #if os(iOS)
                .controlSize(.small)
                #endif

                Button {
                    showMoneybirdSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Moneybird-instellingen")
            }
        }
        .padding(cardPadding)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var copyButton: some View {
        Button {
            copyToClipboard(cutListText)
        } label: {
            Label("Kopieer knip-lijst", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        #if os(iOS)
        .controlSize(.small)
        #endif
    }

    private var exportPDFButton: some View {
        Button {
            exportPDF()
        } label: {
            Label("Exporteer PDF", systemImage: "doc.richtext")
        }
        .buttonStyle(.bordered)
        #if os(iOS)
        .controlSize(.small)
        #endif
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Bouwt één PDF met daarin, per twee kozijnen, een pagina met de naam,
    /// de maten, de schematische tekening en de lijst met stroken, en aan
    /// het eind een pagina met de rolberekening — klaar om op te slaan of te
    /// delen als werkbon voor het knippen van de folie.
    private func exportPDF() {
        guard let data = Self.makePDFData(
            for: kozijnen,
            customerName: linkedCustomer?.name,
            totalStripCount: totalStripCount,
            totalMeters: formattedMeters(rollLengthNeededCm),
            rollsNeeded: rollsNeeded,
            rollLengthM: effectiveRollLengthM
        ) else { return }
        pdfDocument = KozijnenPDFDocument(data: data)
        isExportingPDF = true
    }

    private static func makePDFData(
        for kozijnen: [KozijnItem],
        customerName: String?,
        totalStripCount: Int,
        totalMeters: String,
        rollsNeeded: Int,
        rollLengthM: Double
    ) -> Data? {
        guard !kozijnen.isEmpty else { return nil }

        let pageSize = CGSize(width: 595, height: 842)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        func renderPage<Content: View>(_ content: Content) {
            let sized = content.frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            let renderer = ImageRenderer(content: sized)
            renderer.render { _, context in
                pdfContext.beginPDFPage(nil)
                context(pdfContext)
                pdfContext.endPDFPage()
            }
        }

        // Twee kozijnen per pagina, zodat je niet voor elk kozijn apart een
        // volledig vel hoeft af te drukken.
        let chunks = stride(from: 0, to: kozijnen.count, by: 2).map {
            Array(kozijnen[$0..<min($0 + 2, kozijnen.count)])
        }
        for chunk in chunks {
            renderPage(KozijnPDFSheet(kozijnen: chunk, customerName: customerName))
        }

        renderPage(KozijnPDFTotalsPage(
            customerName: customerName,
            totalStripCount: totalStripCount,
            totalMeters: totalMeters,
            rollsNeeded: rollsNeeded,
            rollWidthCm: Self.rollWidthCm,
            rollLengthM: rollLengthM
        ))

        pdfContext.closePDF()
        return pdfData as Data
    }
}

/// Bestandswrapper zodat de gegenereerde PDF via `.fileExporter` opgeslagen
/// of gedeeld kan worden, op zowel Mac als mobiel.
struct KozijnenPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Eén afdrukbare pagina voor de PDF-export met één of twee kozijnen erop,
/// zodat je niet voor elk kozijn apart een heel vel hoeft af te drukken.
/// Kleuren staan vast op wit/zwart, ongeacht de systeemweergave, zodat de
/// PDF er altijd hetzelfde uitziet.
private struct KozijnPDFSheet: View {
    let kozijnen: [KozijnItem]
    let customerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kozijn wrappen")
                        .font(.title3.bold())
                    if let customerName, !customerName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Klant: \(customerName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Date().formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(kozijnen.enumerated()), id: \.element.id) { index, kozijn in
                if index > 0 {
                    Divider()
                }
                KozijnPDFBlock(kozijn: kozijn)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

/// Het gedeelte voor één kozijn binnen een PDF-pagina: naam, maten, de
/// schematische tekening (niet bij een vensterbank — die heeft geen opening)
/// en de lijst met stroken folie.
private struct KozijnPDFBlock: View {
    let kozijn: KozijnItem

    private func formattedCm(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
    private func formattedMeters(_ cm: Double) -> String {
        (cm / 100).formatted(.number.precision(.fractionLength(0...2)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kozijn.quantity > 1 ? "\(kozijn.displayLabel) · \(kozijn.frameType.title) · Aantal: \(kozijn.quantity)" : "\(kozijn.displayLabel) · \(kozijn.frameType.title)")
                .font(.headline)

            if kozijn.frameType == .windowsill {
                pdfMeasurement("Lengte", kozijn.windowsillLengthCm)
            } else {
                HStack(spacing: 24) {
                    pdfMeasurement("Breedte", kozijn.widthCm)
                    pdfMeasurement("Hoogte", kozijn.heightCm)
                    pdfMeasurement("Profiel", kozijn.frameProfileCm)
                    if kozijn.middleType == .casement {
                        pdfMeasurement("Draairaam b.", kozijn.casementWidthCm)
                        pdfMeasurement("Draairaam h.", kozijn.casementHeightCm)
                    } else if kozijn.middleType == .mullion {
                        pdfMeasurement("Profiel midden", kozijn.secondaryProfileCm)
                    }
                }

                KozijnPreview(
                    widthCm: kozijn.widthCm,
                    heightCm: kozijn.heightCm,
                    frameProfileCm: kozijn.frameProfileCm,
                    frameType: kozijn.frameType,
                    middleType: kozijn.middleType,
                    secondaryProfileCm: kozijn.secondaryProfileCm,
                    casementWidthCm: kozijn.casementWidthCm,
                    casementHeightCm: kozijn.casementHeightCm,
                    casementHorizontalPosition: kozijn.casementHorizontalPosition,
                    mullionHorizontalPosition: kozijn.mullionHorizontalPosition
                )
                .frame(height: 110)
            }

            if !kozijn.parts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Onderdeel").font(.caption2.bold())
                        Spacer()
                        Text("Lengte").font(.caption2.bold()).frame(width: 64, alignment: .trailing)
                        Text("Breedte folie").font(.caption2.bold()).frame(width: 84, alignment: .trailing)
                    }
                    Divider()
                    ForEach(kozijn.parts) { part in
                        HStack {
                            Text(part.label)
                            Spacer()
                            Text("\(formattedCm(part.lengthCm)) cm")
                                .frame(width: 64, alignment: .trailing)
                            Text(part.foilWidthCm > 0 ? "\(formattedCm(part.foilWidthCm)) cm" : "–")
                                .frame(width: 84, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                    Divider()
                    let singleTotal = kozijn.parts.reduce(0) { $0 + $1.lengthCm }
                    let total = singleTotal * Double(kozijn.quantity)
                    HStack {
                        Text(kozijn.quantity > 1 ? "Totaal (× \(kozijn.quantity))" : "Totaal")
                            .font(.caption.bold())
                        Spacer()
                        Text("\(formattedMeters(total)) m")
                            .font(.caption.bold())
                    }
                }
            }
        }
    }

    private func pdfMeasurement(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(formattedCm(value)) cm")
                .font(.caption.bold())
        }
    }
}

/// Slotpagina van de PDF met de rolberekening: hoeveel stroken er in totaal
/// nodig zijn en hoeveel rollen kozijnfolie (120 cm breed, 50 m lang) dat is.
private struct KozijnPDFTotalsPage: View {
    let customerName: String?
    let totalStripCount: Int
    let totalMeters: String
    let rollsNeeded: Int
    let rollWidthCm: Double
    let rollLengthM: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kozijn wrappen — Totalen")
                    .font(.title3.bold())
                if let customerName, !customerName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Klant: \(customerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Rolberekening — kozijnfolie \(Int(rollWidthCm)) cm breed, \(Int(rollLengthM)) m per rol")
                    .font(.headline)
                totalsRow("Totaal aantal stroken", "\(totalStripCount)")
                totalsRow("Totaal benodigde lengte", totalMeters + " m")
                totalsRow("Rollen nodig", "\(rollsNeeded)")
            }
            .padding(16)
            .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func totalsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).bold()
        }
    }
}

/// Schematische voorbeeldweergave van een kozijn op basis van de ingevulde
/// maten: het kozijnprofiel als kader (bij een deur zonder onderdorpel), en
/// — afhankelijk van de middenverdeling — een draairaam (op zijn eigen
/// maten en positie) of een verticaal middenstuk (ook verplaatsbaar) erin.
private struct KozijnPreview: View {
    let widthCm: Double
    let heightCm: Double
    let frameProfileCm: Double
    let frameType: KozijnFrameType
    let middleType: KozijnMiddleType
    let secondaryProfileCm: Double
    let casementWidthCm: Double
    let casementHeightCm: Double
    let casementHorizontalPosition: KozijnHorizontalPosition
    let mullionHorizontalPosition: KozijnHorizontalPosition

    var body: some View {
        GeometryReader { geo in
            let w = max(widthCm, 1)
            let h = max(heightCm, 1)
            let scale = min(geo.size.width / w, geo.size.height / h)
            let boxWidth = w * scale
            let boxHeight = h * scale
            let framePx = min(max(frameProfileCm, 0) * scale, min(boxWidth, boxHeight) / 2 - 1)
            let innerWidth = max(boxWidth - 2 * framePx, 2)
            let isDoor = frameType == .door
            let openingHeight = isDoor ? max(boxHeight - framePx, 2) : max(boxHeight - 2 * framePx, 2)

            ZStack(alignment: isDoor ? .bottom : .center) {
                Rectangle()
                    .fill(Color.brown.opacity(0.55))
                    .frame(width: boxWidth, height: boxHeight)

                switch middleType {
                case .none:
                    Rectangle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: innerWidth, height: openingHeight)
                case .casement:
                    let sashWidth = min(max(casementWidthCm, 1) * scale, innerWidth)
                    let sashHeight = min(max(casementHeightCm, 1) * scale, openingHeight)
                    let sashProfilePx = min(max(secondaryProfileCm, 0) * scale, min(sashWidth, sashHeight) / 2 - 1)
                    let leftGap: CGFloat = {
                        switch casementHorizontalPosition {
                        case .left: return 0
                        case .center: return (innerWidth - sashWidth) / 2
                        case .right: return innerWidth - sashWidth
                        }
                    }()
                    ZStack {
                        Rectangle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: innerWidth, height: openingHeight)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: leftGap)
                            ZStack {
                                Rectangle()
                                    .fill(Color.brown.opacity(0.35))
                                    .frame(width: sashWidth, height: sashHeight)
                                Rectangle()
                                    .fill(Color.blue.opacity(0.28))
                                    .frame(width: max(sashWidth - 2 * sashProfilePx, 2), height: max(sashHeight - 2 * sashProfilePx, 2))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: innerWidth, height: openingHeight)
                    }
                case .mullion:
                    let secondaryPx = min(max(secondaryProfileCm, 0) * scale, innerWidth / 2 - 1)
                    // Een middenstuk zit niet standaard tegen de zijkant van het kozijn
                    // aan, maar staat gewoon wat meer naar links of naar rechts van het
                    // midden — daarom een bescheiden verschuiving vanuit het midden in
                    // plaats van helemaal naar de rand.
                    let centerGap = (innerWidth - secondaryPx) / 2
                    let shift = innerWidth / 6
                    let leftGap: CGFloat = {
                        switch mullionHorizontalPosition {
                        case .left: return max(centerGap - shift, 0)
                        case .center: return centerGap
                        case .right: return min(centerGap + shift, innerWidth - secondaryPx)
                        }
                    }()
                    ZStack {
                        Rectangle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: innerWidth, height: openingHeight)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: leftGap)
                            Rectangle()
                                .fill(Color.brown.opacity(0.55))
                                .frame(width: max(secondaryPx, 1), height: openingHeight)
                            Spacer(minLength: 0)
                        }
                        .frame(width: innerWidth, height: openingHeight)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 130)
    }
}
