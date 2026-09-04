import Foundation

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

enum DiscountMode: String, CaseIterable, Identifiable {
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
struct QuoteItemOption: Hashable {
    var name: String
    var price: Double
}

struct QuoteItem: Hashable {
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

func offerteEmailTemplate(vehicleLines: [String], items: [QuoteItem], totalLabel: String, total: Double) -> String {
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
    out.append(padColumn("Omschrijving") + "Prijs incl. BTW")
    if items.isEmpty {
        out.append("Nog geen werkzaamheden geselecteerd.")
    } else {
        for item in items {
            out.append(padColumn(item.name) + dutchPriceString(item.price))
        }
    }
    out.append("")
    let totalLine = padColumn(totalLabel) + dutchPriceString(total)
    let dashWidth = max(48, totalLine.count)
    let dashes = String(repeating: "-", count: dashWidth)
    out.append(dashes)
    out.append(totalLine)
    out.append(dashes)
    return out.joined(separator: "\n")
}

struct RequestLine: Identifiable, Hashable {
    let id: UUID
    var category: String
    var vehicleLines: [String]
    var items: [QuoteItem]
    var total: Double
    /// Of de prijzen van deze regel al btw bevatten. Bijna alles in de app
    /// rekent met prijzen incl. btw (voor de klantweergave), maar sommige
    /// producten (bijv. Striping) staan als catalogusprijs excl. btw in de
    /// productenlijst. Dit bepaalt alleen hoe de regel naar Moneybird wordt
    /// gestuurd (zie `moneybirdLines`): bij `true` wordt de btw er eerst
    /// afgehaald zodat Moneybird 'm niet dubbel rekent, bij `false` gaat het
    /// bedrag ongewijzigd mee en telt Moneybird zelf de btw erbij op. De
    /// klantweergave (Aanvraag, WhatsApp, e-mail, PDF) blijft in beide
    /// gevallen ongewijzigd.
    var priceIncludesVAT: Bool = true

    init(id: UUID = UUID(), category: String, vehicleLines: [String], items: [QuoteItem], total: Double, priceIncludesVAT: Bool = true) {
        self.id = id
        self.category = category
        self.vehicleLines = vehicleLines
        self.items = items
        self.total = total
        self.priceIncludesVAT = priceIncludesVAT
    }
}

final class RequestStore: ObservableObject {
    @Published var lines: [RequestLine] = []
    @Published var vehicleBrand: String = ""
    @Published var vehicleModel: String = ""
    @Published var vehicleBodyType: String = ""
    @Published var vehicleYear: String = ""

    var total: Double { lines.reduce(0) { $0 + $1.total } }

    var vehicleInfoLines: [String] {
        formatVehicleInfoLines(brand: vehicleBrand, model: vehicleModel, bodyType: vehicleBodyType, year: vehicleYear)
    }

    /// Voegt altijd een nieuwe regel toe (i.p.v. te overschrijven), zodat je bijvoorbeeld
    /// meerdere auto's voor "Ramen tinten" achter elkaar aan de aanvraag kunt toevoegen.
    func add(category: String, items: [QuoteItem], total: Double) {
        lines.append(RequestLine(category: category, vehicleLines: vehicleInfoLines, items: items, total: total))
    }

    func clearVehicleInfo() {
        vehicleBrand = ""
        vehicleModel = ""
        vehicleBodyType = ""
        vehicleYear = ""
    }

    func remove(id: UUID) {
        lines.removeAll { $0.id == id }
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
    }

    /// Zet of de prijzen van deze regel al btw bevatten — zie
    /// `RequestLine.priceIncludesVAT` — bijv. om Striping (catalogusprijs
    /// excl. btw) apart van de rest goed naar Moneybird te laten sturen.
    func setPriceIncludesVAT(lineID: UUID, includesVAT: Bool) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].priceIncludesVAT = includesVAT
    }

    func move(id: UUID, direction: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard lines.indices.contains(target) else { return }
        lines.swapAt(index, target)
    }

    func clear() { lines.removeAll() }
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
