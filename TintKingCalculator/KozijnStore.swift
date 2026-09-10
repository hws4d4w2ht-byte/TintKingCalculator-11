import Foundation

/// Het type kozijn: een raam (met een boven-, onder- en twee zijstijlen), een
/// deur (zonder onderdorpel — de opening loopt door tot de vloer), of een
/// vensterbank (geen kozijn-opening, gewoon één rechte strook op lengte).
enum KozijnFrameType: String, Codable, CaseIterable, Identifiable, Hashable {
    case window
    case door
    case windowsill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return "Raam"
        case .door: return "Deur"
        case .windowsill: return "Vensterbank"
        }
    }
}

/// De middenverdeling van een kozijn: recht (geen verdeling), met een
/// draairaam (een raam dat binnen het kozijn open kan), of met een vast
/// verticaal middenstuk (tussenstijl). Bepaalt welke extra stroken
/// automatisch worden voorgesteld bij "Genereer stroken uit maten".
enum KozijnMiddleType: String, Codable, CaseIterable, Identifiable, Hashable {
    case none
    case casement
    case mullion

    var id: String { rawValue }

    /// Korte titel voor de segmented picker.
    var title: String {
        switch self {
        case .none: return "Recht"
        case .casement: return "Draairaam"
        case .mullion: return "Middenstuk"
        }
    }
}

/// Horizontale positie van het draairaam of het middenstuk binnen de
/// opening van het kozijn, voor als het niet gecentreerd zit (bijvoorbeeld
/// een breed kozijn met een smaller draairaam aan één kant, of een
/// middenstuk dat meer naar links of rechts staat).
enum KozijnHorizontalPosition: String, Codable, CaseIterable, Identifiable, Hashable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Links"
        case .center: return "Midden"
        case .right: return "Rechts"
        }
    }
}

/// Eén strook folie voor een kozijn-onderdeel: de lengte die nodig is en de
/// breedte van de folie die daarvoor gebruikt wordt (voor het knippen van
/// rolletjes folie op maat). Labels zijn vrije tekst, standaard voorgesteld
/// op basis van de maten van het kozijn, maar altijd zelf aan te passen.
struct KozijnPart: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var lengthCm: Double = 0
    var foilWidthCm: Double = 0
}

/// Eén kozijn binnen de huidige berekening: de buitenmaten, het type
/// (raam/deur), de breedte van het profiel, de eventuele middenverdeling
/// (draairaam of middenstuk), het aantal identieke kozijnen, en de stroken
/// folie die daarvoor nodig zijn.
struct KozijnItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var quantity: Int = 1
    var frameType: KozijnFrameType = .window
    var widthCm: Double = 100
    var heightCm: Double = 120
    var frameProfileCm: Double = 6
    var middleType: KozijnMiddleType = .none
    var secondaryProfileCm: Double = 6
    var casementWidthCm: Double = 80
    var casementHeightCm: Double = 100
    var casementHorizontalPosition: KozijnHorizontalPosition = .center
    var mullionHorizontalPosition: KozijnHorizontalPosition = .center
    /// Lengte van een vensterbank — alleen van toepassing als frameType
    /// .windowsill is. Een vensterbank heeft geen kozijn-opening, dus geen
    /// breedte/hoogte/profiel of middenverdeling nodig, gewoon één lengte.
    var windowsillLengthCm: Double = 100
    var parts: [KozijnPart] = []

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nieuw kozijn" : label
    }

    /// Stelt op basis van de ingevulde maten een set stroken voor. Kozijnen
    /// worden meestal in verstek gezet, dus de opgegeven breedte en hoogte
    /// worden direct als lengte gebruikt — zonder de profielbreedte eraf te
    /// trekken. Bij een deur wordt geen onderdorpel voorgesteld. Afhankelijk
    /// van de middenverdeling komen daar de stroken van het draairaam (op
    /// basis van zijn eigen, los ingevulde maten) of het middenstuk bij —
    /// het middenstuk zit wél tussen de boven- en onderregel in en gebruikt
    /// daarom de hoogte min twee keer de profielbreedte. Bij een vensterbank
    /// is er maar één strook, op de ingevulde lengte. De breedte van de folie
    /// (dikte) vul je daarna zelf in per strook.
    func generatedParts() -> [KozijnPart] {
        if frameType == .windowsill {
            return [KozijnPart(label: "Vensterbank", lengthCm: windowsillLengthCm)]
        }

        let innerHeight = max(heightCm - 2 * frameProfileCm, 0)

        var result: [KozijnPart] = [
            KozijnPart(label: "Boven", lengthCm: widthCm),
        ]
        if frameType == .window {
            result.append(KozijnPart(label: "Onder", lengthCm: widthCm))
        }
        result.append(KozijnPart(label: "Links", lengthCm: heightCm))
        result.append(KozijnPart(label: "Rechts", lengthCm: heightCm))

        switch middleType {
        case .none:
            break
        case .casement:
            result.append(contentsOf: [
                KozijnPart(label: "Draairaam boven", lengthCm: casementWidthCm),
                KozijnPart(label: "Draairaam onder", lengthCm: casementWidthCm),
                KozijnPart(label: "Draairaam links", lengthCm: casementHeightCm),
                KozijnPart(label: "Draairaam rechts", lengthCm: casementHeightCm),
            ])
        case .mullion:
            result.append(KozijnPart(label: "Middenstuk", lengthCm: innerHeight))
        }

        return result
    }
}

/// Een opgeslagen kozijn-project: een naam, de kozijnen met hun maten en
/// stroken op dat moment, en de eventueel gekoppelde klant. Zo kun je een
/// lopende berekening bewaren en later weer terugvinden, in plaats van hem
/// telkens opnieuw in te vullen.
struct KozijnProject: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var kozijnen: [KozijnItem] = []
    var linkedCustomerID: UUID?
    var modifiedAt: Date = Date()

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Naamloos project" : name
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kozijnen, linkedCustomerID, modifiedAt
    }

    init(id: UUID = UUID(), name: String = "", kozijnen: [KozijnItem] = [], linkedCustomerID: UUID? = nil, modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kozijnen = kozijnen
        self.linkedCustomerID = linkedCustomerID
        self.modifiedAt = modifiedAt
    }

    /// Handgeschreven, in plaats van de automatisch gesynthetiseerde
    /// Decodable, zodat een `modifiedAt` dat ontbreekt in een ouder, al
    /// lokaal opgeslagen bestand niet het hele bestand — dus alle
    /// kozijn-projecten — onleesbaar maakt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kozijnen = try container.decodeIfPresent([KozijnItem].self, forKey: .kozijnen) ?? []
        linkedCustomerID = try container.decodeIfPresent(UUID.self, forKey: .linkedCustomerID)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kozijnen, forKey: .kozijnen)
        try container.encodeIfPresent(linkedCustomerID, forKey: .linkedCustomerID)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}
