import Foundation
import CloudKit

let carBodyTypes: [String] = [
    "Hatchback (3 deuren)",
    "Hatchback (5 deuren)",
    "Sedan",
    "Station",
    "SUV / Crossover",
    "SUV groot",
    "Coupe",
    "Pick-up"
]

enum DiscountMode: String, CaseIterable, Identifiable, Codable {
    case none = "Geen korting"
    case percentage = "Percentage"
    case fixed = "Vast bedrag"

    var id: String { rawValue }
}

func discountValue(total: Double, mode: DiscountMode, percentage: Double, fixedAmount: Double) -> Double {
    switch mode {
    case .none:
        return 0
    case .percentage:
        return min(max(total * (percentage / 100.0), 0), total)
    case .fixed:
        return min(max(fixedAmount, 0), total)
    }
}

func afterDiscount(total: Double, mode: DiscountMode, percentage: Double, fixedAmount: Double) -> Double {
    max(total - discountValue(total: total, mode: mode, percentage: percentage, fixedAmount: fixedAmount), 0)
}

func excludingVAT(fromIncludingVAT amount: Double) -> Double {
    amount / 1.21
}

func includingVAT(fromExcludingVAT amount: Double) -> Double {
    amount * 1.21
}

func dutchPriceString(_ amount: Double) -> String {
    let sign = amount < 0 ? "-" : ""
    let absAmount = abs(amount)
    let rounded = (absAmount * 100).rounded() / 100
    if rounded.rounded() == rounded {
        return "\(sign)€ \(Int(rounded)),-"
    }
    let formatted = String(format: "%.2f", rounded).replacingOccurrences(of: ".", with: ",")
    return "\(sign)€ \(formatted)"
}

func padColumn(_ text: String, width: Int = 30) -> String {
    if text.count >= width { return text + "  " }
    return text + String(repeating: " ", count: width - text.count)
}

/// Eén gekozen submenu-optie (bijv. "Zwart" bij "Kleur") met de meerprijs die
/// erbij hoort, voor het los tonen van wat zo'n optie/"subproduct" kost in de
/// Aanvraag — apart van de totale regelprijs.
struct QuoteItemOption: Hashable, Codable {
    var name: String
    var price: Double
}

struct QuoteItem: Hashable, Codable {
    var name: String
    var price: Double

    /// Gekozen submenu-opties met hun eigen (meer)prijs, bijv. Kleur: Zwart
    /// +€5,00 — zodat je in de Aanvraag ook los kunt zien wat zo'n optie
    /// kost, in plaats van alleen de totale regelprijs. Alleen gevuld voor
    /// producten met een submenu; voor alle andere regels (calculators,
    /// kortingen, enz.) blijft dit leeg.
    var optionBreakdown: [QuoteItemOption] = []

    /// `name` bevat soms een los toegevoegde notitie (bijv. kenteken of
    /// gebruikte kleur folie), samengevoegd als "Titel — notitie". Voor
    /// weergave in de Aanvraag splitsen we dat op de eerste " — " zodat de
    /// notitie op een eigen regel onder de titel kan komen te staan, zonder
    /// de opgeslagen `name` zelf te veranderen (die blijft ongewijzigd
    /// gebruikt voor export, WhatsApp, e-mail en Moneybird).
    ///
    /// Is er ook een `optionBreakdown` (submenu-opties met eigen prijs), dan
    /// wordt de meegevouwen "(optie1, optie2)" uit de titel gehaald — die
    /// opties komen dan als eigen regel met prijs onder de titel te staan
    /// (zie `requestItemRow`), zodat het niet dubbel getoond wordt.
    var displayTitle: String {
        var title = name
        if let dashRange = title.range(of: " — ") {
            title = String(title[title.startIndex..<dashRange.lowerBound])
        }
        if !optionBreakdown.isEmpty, title.hasSuffix(")"), let openParenRange = title.range(of: " (", options: .backwards) {
            title = String(title[title.startIndex..<openParenRange.lowerBound])
        }
        return title
    }

    var displayNote: String? {
        guard let range = name.range(of: " — ") else { return nil }
        let note = String(name[range.upperBound...])
        return note.isEmpty ? nil : note
    }
}

/// Eén regel in de Snijfolie-calculator: één sticker/ontwerp met eigen afmeting,
/// aantal, materiaal (uit de Prijslijst) en snijcomplexiteit.
struct CutFoilLineItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var materialID: String
    var widthCm: Double
    var heightCm: Double
    var quantity: Int
    var complexity: CutComplexity

    init(
        id: UUID = UUID(),
        name: String = "",
        materialID: String,
        widthCm: Double = 0,
        heightCm: Double = 0,
        quantity: Int = 1,
        complexity: CutComplexity = .medium
    ) {
        self.id = id
        self.name = name
        self.materialID = materialID
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.quantity = quantity
        self.complexity = complexity
    }

    /// Hoeveel exemplaren van dit ontwerp naast elkaar passen over de bruikbare
    /// rolbreedte (rolbreedte minus machinemarge).
    func piecesPerRow(usableWidthCm: Double) -> Int {
        guard widthCm > 0, usableWidthCm > 0 else { return 0 }
        return max(0, Int((usableWidthCm / widthCm).rounded(.down)))
    }

    /// Hoeveel rijen (over de lengte van de rol) nodig zijn om `quantity`
    /// exemplaren te plotten, gegeven de bruikbare rolbreedte.
    func rowsNeeded(usableWidthCm: Double) -> Int {
        let perRow = piecesPerRow(usableWidthCm: usableWidthCm)
        guard perRow > 0, quantity > 0 else { return 0 }
        return Int((Double(quantity) / Double(perRow)).rounded(.up))
    }

    /// Werkelijk gebruikte rollengte in cm. Elke rij gebruikt de volle hoogte van
    /// dit ontwerp, ongeacht hoeveel van de rijbreedte daadwerkelijk gevuld is —
    /// zo tel je de "restruimte" naast een oneven aantal stuks netjes mee.
    func rollLengthCm(usableWidthCm: Double) -> Double {
        Double(rowsNeeded(usableWidthCm: usableWidthCm)) * max(heightCm, 0)
    }

    /// Werkelijk gebruikte oppervlakte in m², gebaseerd op de volle bruikbare
    /// rolbreedte (dus inclusief het "vullen van het vel").
    func areaM2(usableWidthCm: Double) -> Double {
        (max(usableWidthCm, 0) / 100.0) * (rollLengthCm(usableWidthCm: usableWidthCm) / 100.0)
    }

    /// Of dit ontwerp breder is dan de bruikbare rolbreedte (past dan helemaal niet).
    func exceedsRollWidth(usableWidthCm: Double) -> Bool {
        usableWidthCm > 0 && widthCm > usableWidthCm
    }

    /// Kale oppervlakte van alleen dit ontwerp (breedte × hoogte × aantal), zonder
    /// rekening te houden met hoe het op de rol past. Gebruikt om de arbeidskosten
    /// naar verhouding te laten meeschalen met zowel de afmeting als het aantal.
    var naiveAreaM2: Double {
        max(widthCm, 0) / 100.0 * max(heightCm, 0) / 100.0 * Double(max(quantity, 0))
    }

    /// Materiaalkosten van deze regel: werkelijk gebruikte rollengte × materiaalprijs
    /// per m². Blijft gelijk zolang het aantal in dezelfde rij past.
    func materialCost(pricePerM2: Double, usableWidthCm: Double) -> Double {
        areaM2(usableWidthCm: usableWidthCm) * pricePerM2
    }

    /// Extra kosten voor het snij-/wiedwerk: (kale oppervlakte van dit ontwerp) ×
    /// (arbeidsprijs per m²) × complexiteitsfactor. Schaalt dus zowel met het
    /// aantal stuks als met de afmeting van elke sticker — een dubbel zo grote
    /// sticker kost ook dubbel zoveel arbeid, ook bij "Eenvoudig".
    func laborSurcharge(laborPricePerM2: Double, complexityMultiplier: Double) -> Double {
        naiveAreaM2 * max(laborPricePerM2, 0) * complexityMultiplier
    }

    /// Totale prijs van deze regel: materiaalkosten (o.b.v. werkelijk rolgebruik)
    /// + arbeidskosten (o.b.v. afmeting, aantal en complexiteit), met een bodem van
    /// (minimumprijs per stuk × aantal) — zo kost een klein simpel stickertje nooit
    /// minder dan je minimumtarief, ook al is de materiaal+arbeidsberekening lager.
    func price(pricePerM2: Double, usableWidthCm: Double, laborPricePerM2: Double, minimumPricePerPiece: Double, complexityMultiplier: Double) -> Double {
        let raw = materialCost(pricePerM2: pricePerM2, usableWidthCm: usableWidthCm) + laborSurcharge(laborPricePerM2: laborPricePerM2, complexityMultiplier: complexityMultiplier)
        let floor = max(minimumPricePerPiece, 0) * Double(max(quantity, 0))
        return max(raw, floor)
    }

    /// Gemiddelde prijs per stuk van deze regel (totale regelprijs / aantal).
    func pricePerPiece(pricePerM2: Double, usableWidthCm: Double, laborPricePerM2: Double, minimumPricePerPiece: Double, complexityMultiplier: Double) -> Double {
        guard quantity > 0 else { return 0 }
        return price(pricePerM2: pricePerM2, usableWidthCm: usableWidthCm, laborPricePerM2: laborPricePerM2, minimumPricePerPiece: minimumPricePerPiece, complexityMultiplier: complexityMultiplier) / Double(quantity)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sticker" : trimmed
    }
}

/// Standaard rolbreedtes voor de Snijfolie-calculator. "Aangepast" laat een
/// vrij in te vullen breedte toe.
enum CutFoilRollPreset: String, CaseIterable, Identifiable {
    case cm60 = "60 cm"
    case cm122 = "122 cm"
    case custom = "Aangepast"

    var id: String { rawValue }

    var widthCm: Double? {
        switch self {
        case .cm60: return 60
        case .cm122: return 122
        case .custom: return nil
        }
    }
}

func formatVehicleInfoLines(brand: String, model: String, bodyType: String, year: String) -> [String] {
    var result: [String] = []
    let b = brand.trimmingCharacters(in: .whitespacesAndNewlines)
    let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let t = bodyType.trimmingCharacters(in: .whitespacesAndNewlines)
    let y = year.trimmingCharacters(in: .whitespacesAndNewlines)
    if !b.isEmpty { result.append("Merk: \(b)") }
    if !m.isEmpty { result.append("Model: \(m)") }
    if !t.isEmpty { result.append("Carrosserie: \(t)") }
    if !y.isEmpty { result.append("Bouwjaar: \(y)") }
    return result
}

func offerteEmailTemplate(vehicleLines: [String], items: [QuoteItem], totalLabel: String, total: Double, showExcludingVATBreakdown: Bool = false, itemsExcludeVAT: Bool = false) -> String {
    var out: [String] = []
    if !vehicleLines.isEmpty {
        out.append("VOERTUIG")
        out.append(String(repeating: "-", count: 8))
        out.append(contentsOf: vehicleLines)
        out.append("")
    }
    out.append("OFFERTE")
    out.append(String(repeating: "-", count: 7))
    out.append("")

    // Kolombreedte dynamisch op de langste regel afstemmen (i.p.v. de vaste
    // standaardbreedte van padColumn), zodat ook een lange omschrijving (bijv.
    // "Moeilijkheids-, risico- en overige toeslag") niet uit de kolom loopt —
    // de bedragen blijven zo altijd netjes onder elkaar staan, zolang dit in
    // een monospaced lettertype getoond wordt.
    let summaryLabels = itemsExcludeVAT ? ["Subtotaal excl. btw", "Btw (21%)", "TOTAAL incl. btw"] : [totalLabel]
    let allLabels = ["Omschrijving"] + items.map(\.name) + summaryLabels
    let columnWidth = max(30, (allLabels.map(\.count).max() ?? 0) + 2)

    let priceHeader = itemsExcludeVAT ? "Prijs excl. BTW" : "Prijs incl. BTW"
    out.append(padColumn("Omschrijving", width: columnWidth) + priceHeader)
    if items.isEmpty {
        out.append("Nog geen werkzaamheden geselecteerd.")
    } else {
        for item in items {
            out.append(padColumn(item.name, width: columnWidth) + dutchPriceString(item.price))
        }
    }
    out.append("")

    if itemsExcludeVAT {
        // Voor zakelijke offertes (bijv. Montage): de regels hierboven staan
        // zelf al excl. btw, en onderaan komt de volledige opbouw excl. → btw
        // → incl. i.p.v. één totaalregel incl. btw. `total` blijft, net als
        // bij de andere calculators, het bedrag incl. btw — de excl.- en
        // btw-bedragen worden hieruit afgeleid.
        let excl = excludingVAT(fromIncludingVAT: total)
        let btw = total - excl
        let exclLine = padColumn(summaryLabels[0], width: columnWidth) + dutchPriceString(excl)
        let dashWidth = max(48, exclLine.count)
        let dashes = String(repeating: "-", count: dashWidth)
        out.append(dashes)
        out.append(exclLine)
        out.append(padColumn(summaryLabels[1], width: columnWidth) + dutchPriceString(btw))
        out.append(padColumn(summaryLabels[2], width: columnWidth) + dutchPriceString(total))
        out.append(dashes)
    } else {
        let totalLine = padColumn(totalLabel, width: columnWidth) + dutchPriceString(total)
        let dashWidth = max(48, totalLine.count)
        let dashes = String(repeating: "-", count: dashWidth)
        out.append(dashes)
        out.append(totalLine)
        out.append(dashes)
        // "Weergave prijsopgave"-knop: toont er, als gewenst, de excl.-btw- en
        // btw-regel onder de totaalbalk bij, zowel voor e-mail als WhatsApp —
        // dezelfde opmaak die de Aanvraag-pagina al gebruikt.
        if showExcludingVATBreakdown {
            let excl2 = excludingVAT(fromIncludingVAT: total)
            out.append("")
            out.append(padColumn("Totaal excl. btw", width: columnWidth) + dutchPriceString(excl2))
            out.append(padColumn("Btw 21%", width: columnWidth) + dutchPriceString(total - excl2))
        }
    }
    return out.joined(separator: "\n")
}

struct RequestLine: Identifiable, Hashable, Codable {
    let id: UUID
    var category: String
    var vehicleLines: [String]
    var items: [QuoteItem]
    var total: Double
    /// Of de prijzen van deze regel al btw bevatten. Bijna alles in de app
    /// rekent met prijzen incl. btw (voor de klantweergave), maar sommige
    /// producten (bijv. Striping) staan als catalogusprijs excl. btw in de
    /// productenlijst. Dit bepaalt hoe de regel naar Moneybird wordt gestuurd
    /// (zie `moneybirdLines`) én hoe de kopieerknoppen (WhatsApp/e-mail) 'm
    /// laten zien: bij `true` verandert er niets, bij `false` wordt de btw er
    /// bij Moneybird eerst afgehaald (zodat 't niet dubbel gerekend wordt) en
    /// juist bij het kopiëren van de klanttekst weer bovenop gezet (zie
    /// `displayTotal`). Het Aanvraag-scherm zelf (het totaalbedrag dat je
    /// hier ziet) verandert door deze knop bewust niet — die toont altijd
    /// gewoon `total`.
    var priceIncludesVAT: Bool = true
    /// Voor cloud-synchronisatie: bij een conflict (dezelfde regel op twee
    /// apparaten gewijzigd) wint de nieuwste wijziging — zie `RequestStore`.
    var modifiedAt: Date = Date()

    init(id: UUID = UUID(), category: String, vehicleLines: [String], items: [QuoteItem], total: Double, priceIncludesVAT: Bool = true, modifiedAt: Date = Date()) {
        self.id = id
        self.category = category
        self.vehicleLines = vehicleLines
        self.items = items
        self.total = total
        self.priceIncludesVAT = priceIncludesVAT
        self.modifiedAt = modifiedAt
    }

    /// Regel-subtotaal zoals het in de kopieerknoppen (WhatsApp/e-mail) komt
    /// te staan: staat de regel op "excl. btw" (zie `priceIncludesVAT`), dan
    /// komt de btw hier alsnog bij, zodat de gekopieerde tekst het bedrag
    /// toont dat de klant echt moet betalen. Wordt bewust NIET gebruikt voor
    /// het Aanvraag-scherm zelf (zie `RequestStore.total`) — alleen voor de
    /// kopieertekst.
    var displayTotal: Double {
        priceIncludesVAT ? total : includingVAT(fromExcludingVAT: total)
    }
}

@MainActor
final class RequestStore: ObservableObject {
    @Published var lines: [RequestLine] = []
    @Published var vehicleBrand: String = ""
    @Published var vehicleModel: String = ""
    @Published var vehicleBodyType: String = ""
    @Published var vehicleYear: String = ""
    /// De klant (uit Klantgegevens) waar deze aanvraag voor is — gedeeld
    /// tussen Ramen tinten, Ontchromen, Snijfolie en Aanvraag (die allemaal
    /// dezelfde RequestStore gebruiken), zodat je 'm maar op één plek hoeft
    /// te kiezen. Bepaalt, als de klant een Moneybird-koppeling heeft, naar
    /// welke Moneybird-klant de Aanvraag geëxporteerd wordt in plaats van de
    /// vaste placeholder-klant.
    @Published var linkedCustomerID: UUID?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.Aanvraag.Lines.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedRequestLineIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingRequestLineDeletions"

    init() {
        load()
        Task { await syncWithCloud() }
    }

    var total: Double { lines.reduce(0) { $0 + $1.total } }

    var vehicleInfoLines: [String] {
        formatVehicleInfoLines(brand: vehicleBrand, model: vehicleModel, bodyType: vehicleBodyType, year: vehicleYear)
    }

    /// Voegt altijd een nieuwe regel toe (i.p.v. te overschrijven), zodat je bijvoorbeeld
    /// meerdere auto's voor "Ramen tinten" achter elkaar aan de aanvraag kunt toevoegen.
    func add(category: String, items: [QuoteItem], total: Double) {
        let line = RequestLine(category: category, vehicleLines: vehicleInfoLines, items: items, total: total)
        lines.append(line)
        persistLocally()
        Task { await push(line) }
    }

    func clearVehicleInfo() {
        vehicleBrand = ""
        vehicleModel = ""
        vehicleBodyType = ""
        vehicleYear = ""
    }

    func remove(id: UUID) {
        lines.removeAll { $0.id == id }
        persistLocally()
        addPendingDeletion(id)
        Task { await flushPendingDeletions() }
    }

    /// Past de naam en/of prijs van één regel-item aan (bijv. om een kenteken
    /// of kleur folie toe te voegen, of een typefout te corrigeren, direct
    /// vanuit de Aanvraag). Werkt op de positie in de lijst (niet op de
    /// waarde) zodat het ook goed gaat als twee items toevallig dezelfde naam
    /// en prijs hebben. De subtotaal (`total`) van de regel schuift mee met
    /// het prijsverschil, zodat extra logica die al in `total` verwerkt zat
    /// (zoals een minimumprijs) niet verloren gaat.
    func updateItem(lineID: UUID, itemIndex: Int, newName: String, newPrice: Double) {
        guard let lineIndex = lines.firstIndex(where: { $0.id == lineID }) else { return }
        guard lines[lineIndex].items.indices.contains(itemIndex) else { return }
        let priceDelta = newPrice - lines[lineIndex].items[itemIndex].price
        lines[lineIndex].items[itemIndex].name = newName
        lines[lineIndex].items[itemIndex].price = newPrice
        lines[lineIndex].total += priceDelta
        lines[lineIndex].modifiedAt = Date()
        persistLocally()
        Task { await push(lines[lineIndex]) }
    }

    /// Zet of de prijzen van deze regel al btw bevatten — zie
    /// `RequestLine.priceIncludesVAT` — bijv. om Striping (catalogusprijs
    /// excl. btw) apart van de rest goed naar Moneybird te laten sturen.
    func setPriceIncludesVAT(lineID: UUID, includesVAT: Bool) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].priceIncludesVAT = includesVAT
        lines[index].modifiedAt = Date()
        persistLocally()
        Task { await push(lines[index]) }
    }

    func move(id: UUID, direction: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard lines.indices.contains(target) else { return }
        lines.swapAt(index, target)
        persistLocally()
    }

    func clear() {
        let ids = lines.map(\.id)
        lines.removeAll()
        persistLocally()
        for id in ids { addPendingDeletion(id) }
        Task { await flushPendingDeletions() }
    }

    // MARK: - Lokale opslag

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RequestLine].self, from: data) else { return }
        lines = decoded
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Cloud-synchronisatie
    //
    // Elke regel in de aanvraag is een los record (op id), net als bij
    // ProjectStore/CustomerStore — zo overschrijft een wijziging op het ene
    // apparaat niet de wijzigingen van een ander apparaat. De voertuig-
    // scratchvelden (`vehicleBrand` e.d.) en `linkedCustomerID` worden bewust
    // niet gesynchroniseerd: dat is tijdelijke invoer voor de eerstvolgende
    // regel, geen vastgelegde data.

    private var syncedIDs: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: syncedIDsKey) as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: syncedIDsKey) }
    }

    private var pendingDeletions: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: pendingDeletionsKey) as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: pendingDeletionsKey) }
    }

    private func addPendingDeletion(_ id: UUID) {
        var current = pendingDeletions
        current.insert(id)
        pendingDeletions = current
        var synced = syncedIDs
        synced.remove(id)
        syncedIDs = synced
    }

    /// Haalt de laatste stand op, voegt regels van andere apparaten toe, werkt
    /// gewijzigde regels bij, en verwijdert regels die elders zijn verwijderd.
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: RequestLine.recordType)
        let remoteLines = remoteRecords.compactMap(RequestLine.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteLines.map { ($0.id, $0) })

        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var idsToRemove: Set<UUID> = []
        var merged = lines
        var changed = false

        // Bestaande regels op hun huidige plek bijwerken met een nieuwere
        // versie van een ander apparaat — bewust GEEN herschikking van de
        // hele lijst, zodat de volgorde die je zelf met de pijltjes-knoppen
        // hebt ingesteld intact blijft.
        for index in merged.indices {
            let local = merged[index]
            if let remote = remoteByID[local.id] {
                currentSyncedIDs.insert(local.id)
                if remote.modifiedAt > local.modifiedAt {
                    merged[index] = remote
                    changed = true
                } else if local.modifiedAt > remote.modifiedAt {
                    idsToPush.append(local.id)
                }
            } else if currentSyncedIDs.contains(local.id) {
                // Was al eens gesynchroniseerd maar staat nu niet meer in de
                // cloud: elders verwijderd.
                idsToRemove.insert(local.id)
            } else {
                idsToPush.append(local.id)
            }
        }
        if !idsToRemove.isEmpty {
            merged.removeAll { idsToRemove.contains($0.id) }
            changed = true
        }

        // Nieuwe regels van andere apparaten die hier nog niet bestaan: achteraan toevoegen.
        let localIDs = Set(merged.map(\.id))
        for remote in remoteLines where !localIDs.contains(remote.id) {
            merged.append(remote)
            currentSyncedIDs.insert(remote.id)
            changed = true
        }

        syncedIDs = currentSyncedIDs

        if changed {
            lines = merged
            persistLocally()
        }

        for id in idsToPush {
            if let line = merged.first(where: { $0.id == id }) {
                await push(line)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ line: RequestLine) async {
        let record = line.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(line.id)
            syncedIDs = synced
        }
    }

    private func flushPendingDeletions() async {
        let ids = pendingDeletions
        guard !ids.isEmpty else { return }
        let recordIDs = ids.map { CloudSyncCenter.shared.recordID(name: $0.uuidString) }
        if await CloudSyncCenter.shared.delete(recordIDs: recordIDs) {
            pendingDeletions = []
        }
    }
}

// MARK: - Cloud-mapping

private extension RequestLine {
    static let recordType = "RequestLine"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["category"] = category as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        record["total"] = total as NSNumber
        record["priceIncludesVAT"] = (priceIncludesVAT ? 1.0 : 0.0) as NSNumber
        if let data = try? JSONEncoder().encode(vehicleLines), let json = String(data: data, encoding: .utf8) {
            record["vehicleLinesJSON"] = json as NSString
        }
        if let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8) {
            record["itemsJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let category = record["category"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date,
            let totalNumber = record["total"] as? NSNumber,
            let vehicleLinesJSON = record["vehicleLinesJSON"] as? String,
            let vehicleLinesData = vehicleLinesJSON.data(using: .utf8),
            let vehicleLines = try? JSONDecoder().decode([String].self, from: vehicleLinesData),
            let itemsJSON = record["itemsJSON"] as? String,
            let itemsData = itemsJSON.data(using: .utf8),
            let items = try? JSONDecoder().decode([QuoteItem].self, from: itemsData)
        else { return nil }
        let priceIncludesVATNumber = (record["priceIncludesVAT"] as? NSNumber)?.doubleValue ?? 1.0
        self.init(
            id: id,
            category: category,
            vehicleLines: vehicleLines,
            items: items,
            total: totalNumber.doubleValue,
            priceIncludesVAT: priceIncludesVATNumber >= 0.5,
            modifiedAt: modifiedAt
        )
    }
}

struct TintPriceItem: Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
    let category: String

    init(_ name: String, _ price: Double, _ category: String) {
        self.id = name
        self.name = name
        self.price = price
        self.category = category
    }
}

struct DechromePart: Identifiable, Hashable {
    let id: String
    let name: String
    let basePrice: Double

    init(_ name: String, _ basePrice: Double) {
        self.id = name
        self.name = name
        self.basePrice = basePrice
    }
}

let dechromePresets: [String: [String: Double]] = [
    "Audi E-Tron": [
        "Raamlijsten Ontchromen": 250, "Dakdrails Ontchromen": 200, "Spiegels": 120,
        "Voorskirt": 120, "Grill ontchromen": 160, "Diffuser": 160, "Logo pakket": 200
    ],
    "Audi Q4 E-Tron": [
        "Raamlijsten Ontchromen": 160, "Dakdrails Ontchromen": 200, "Grill omlijsting Ontchromen": 100,
        "Deurstrips": 120, "Voorbumper": 160, "Achterbumper": 180
    ],
    "Audi Q5": [
        "Raamlijsten Ontchromen": 250, "Dakdrails Ontchromen": 200, "Diffuser": 80,
        "Grill ontchromen": 160, "Voorbumper": 60, "Logo pakket": 180
    ],
    "BMW X5": [
        "Raamlijsten Ontchromen": 250, "Dakdrails Ontchromen": 200, "Voorbumper": 85,
        "Dorpels": 80, "Zijschermen / spatbord": 80, "Uitlaat tips Ontchromen": 70, "Diffuser": 120
    ],
    "Mercedes GLB": [
        "Raamlijsten Ontchromen": 250, "Dakdrails Ontchromen": 200, "Deurstrips": 100,
        "Voorbumper": 80, "Achterbumper": 120, "Grill omlijsting Ontchromen": 60
    ],
    "Mini": [
        "Beltline Ontchromen": 240, "Grill ontchromen": 100, "Handgrepen Ontchromen": 80
    ],
    "Tesla Model 3": [
        "Raamlijsten Ontchromen": 350, "Zijschermen / spatbord": 60, "Handgrepen Ontchromen": 100,
        "Logo voor": 40, "Logo achter": 40
    ],
    "Volvo XC60": [
        "Raamlijsten Ontchromen": 250, "Dakdrails Ontchromen": 200, "Grill ontchromen": 100,
        "Logo voor": 60, "Voorbumper": 60, "Achterbumper": 50, "Diffuser": 80
    ],
    "Volvo XC40": [
        "Raamlijsten Ontchromen": 140, "Dakdrails Ontchromen": 200, "Grill ontchromen": 100,
        "Logo voor": 60, "Voorbumper": 120, "Deurstrips": 80
    ],
    "Volvo V60": [
        "Dakdrails Ontchromen": 200, "Raamlijsten Ontchromen": 250, "Grill ontchromen": 120,
        "Logo voor": 60, "Voorbumper": 60, "Achterbumper": 50
    ],
    "Kia Sportage": [
        "Raamlijsten Ontchromen": 240, "Voorbumper": 80, "Spoiler": 100,
        "Achterbumper": 60, "Diffuser": 100, "Logo voor": 50, "Logo achter": 50
    ],
    "Kia Proceed": [
        "Raamlijsten Ontchromen": 260, "Grill ontchromen": 80, "Voorbumper": 60, "Dorpels": 80
    ],
    "Lync & Co": [
        "blauwe raamlijst": 180, "blauwe strip grill": 60, "chrome oplaadklep": 40
    ]
]

// MARK: - WhatsApp-koppeling

/// Bouwt een wa.me-link met vooraf ingevuld bericht, zodat WhatsApp direct
/// opent met de tekst klaar om te versturen — in plaats van eerst te moeten
/// kopiëren en plakken. Herkent Nederlandse nummers zonder landcode (bijv.
/// "06 1234 5678" of een vast nummer met "0" ervoor) en zet die om naar +31.
enum WhatsAppLink {
    static func url(phone: String, message: String) -> URL? {
        var digits = phone.filter { $0.isNumber || $0 == "+" }
        guard digits.contains(where: \.isNumber) else { return nil }
        if digits.hasPrefix("+") {
            digits.removeFirst()
        } else if digits.hasPrefix("00") {
            digits.removeFirst(2)
        } else if digits.hasPrefix("0") {
            digits = "31" + digits.dropFirst()
        }
        guard let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://wa.me/\(digits)?text=\(encodedMessage)")
    }
}
