import Foundation

struct MaterialLine: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var cost: Double
    var markup: Double

    var charged: Double { cost * (1 + markup) }
}

enum Difficulty: String, CaseIterable, Identifiable, Codable {
    case normal = "Normaal"
    case hard = "Lastig"
    case veryHard = "Zeer lastig"

    var id: String { rawValue }

    /// Het opslagpercentage voor dit niveau — instelbaar via de Instellingen-knop
    /// (zie `CalculatorSettings`) in plaats van hier vast te liggen.
    func percentage(in settings: CalculatorSettings) -> Double {
        switch self {
        case .normal: return settings.difficultyNormalPercentage
        case .hard: return settings.difficultyHardPercentage
        case .veryHard: return settings.difficultyVeryHardPercentage
        }
    }

    /// Vermenigvuldigingsfactor die met het opslagpercentage overeenkomt.
    func factor(in settings: CalculatorSettings) -> Double {
        1 + percentage(in: settings)
    }
}

enum RiskLevel: String, CaseIterable, Identifiable, Codable {
    case low = "Laag"
    case normal = "Normaal"
    case high = "Hoog"

    var id: String { rawValue }

    /// Het opslagpercentage voor dit niveau — instelbaar via de Instellingen-knop
    /// (zie `CalculatorSettings`) in plaats van hier vast te liggen.
    func percentage(in settings: CalculatorSettings) -> Double {
        switch self {
        case .low: return settings.riskLowPercentage
        case .normal: return settings.riskNormalPercentage
        case .high: return settings.riskHighPercentage
        }
    }
}

/// Snijcomplexiteit voor de Snijfolie-calculator: hoeveel handwerk (wieden) een
/// ontwerp kost bovenop de kale materiaalprijs. Zelfde soort factor-systeem als
/// Difficulty hierboven, maar dan voor snijfolie/plotterwerk.
enum CutComplexity: String, CaseIterable, Identifiable, Codable {
    case simple = "Eenvoudig"
    case medium = "Gemiddeld"
    case complex = "Complex"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .simple: return 1.0
        case .medium: return 1.3
        case .complex: return 1.6
        }
    }

    var helpText: String {
        switch self {
        case .simple: return "Grote, gesloten vormen — snel te wieden"
        case .medium: return "Gemiddeld detail, wat handwerk"
        case .complex: return "Veel kleine tekst/details — veel wiedwerk"
        }
    }
}

struct CalculatorSettings: Equatable {
    var hourlyRate: Double = 75
    var travelHourlyRate: Double = 25
    var kmRate: Double = 0.35
    var rushPercentage: Double = 0.15
    // Moeilijkheids- en risico-opslagen: eerder vaste percentages per niveau
    // (Difficulty/RiskLevel hierboven), nu hier aanpasbaar via de Instellingen-
    // knop, net als de tarieven hierboven. Normaal (moeilijkheid) en Laag
    // (risico) staan standaard op 0% — de rest op de oude standaardwaarden.
    var difficultyNormalPercentage: Double = 0
    var difficultyHardPercentage: Double = 0.10
    var difficultyVeryHardPercentage: Double = 0.20
    var riskLowPercentage: Double = 0
    var riskNormalPercentage: Double = 0.10
    var riskHighPercentage: Double = 0.15

    private enum CodingKeys: String, CodingKey {
        case hourlyRate, travelHourlyRate, kmRate, rushPercentage
        case difficultyNormalPercentage, difficultyHardPercentage, difficultyVeryHardPercentage
        case riskLowPercentage, riskNormalPercentage, riskHighPercentage
    }

    init(
        hourlyRate: Double = 75,
        travelHourlyRate: Double = 25,
        kmRate: Double = 0.35,
        rushPercentage: Double = 0.15,
        difficultyNormalPercentage: Double = 0,
        difficultyHardPercentage: Double = 0.10,
        difficultyVeryHardPercentage: Double = 0.20,
        riskLowPercentage: Double = 0,
        riskNormalPercentage: Double = 0.10,
        riskHighPercentage: Double = 0.15
    ) {
        self.hourlyRate = hourlyRate
        self.travelHourlyRate = travelHourlyRate
        self.kmRate = kmRate
        self.rushPercentage = rushPercentage
        self.difficultyNormalPercentage = difficultyNormalPercentage
        self.difficultyHardPercentage = difficultyHardPercentage
        self.difficultyVeryHardPercentage = difficultyVeryHardPercentage
        self.riskLowPercentage = riskLowPercentage
        self.riskNormalPercentage = riskNormalPercentage
        self.riskHighPercentage = riskHighPercentage
    }
}

extension CalculatorSettings: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hourlyRate = try container.decodeIfPresent(Double.self, forKey: .hourlyRate) ?? 75
        travelHourlyRate = try container.decodeIfPresent(Double.self, forKey: .travelHourlyRate) ?? 25
        kmRate = try container.decodeIfPresent(Double.self, forKey: .kmRate) ?? 0.35
        rushPercentage = try container.decodeIfPresent(Double.self, forKey: .rushPercentage) ?? 0.15
        // Handgeschreven, in plaats van de automatisch gesynthetiseerde Decodable,
        // zodat deze nieuwe velden — als ze ontbreken in een al opgeslagen project
        // van vóór deze aanpasbare instellingen — terugvallen op de oude vaste
        // waarden in plaats van dat het hele project onleesbaar wordt.
        difficultyNormalPercentage = try container.decodeIfPresent(Double.self, forKey: .difficultyNormalPercentage) ?? 0
        difficultyHardPercentage = try container.decodeIfPresent(Double.self, forKey: .difficultyHardPercentage) ?? 0.10
        difficultyVeryHardPercentage = try container.decodeIfPresent(Double.self, forKey: .difficultyVeryHardPercentage) ?? 0.20
        riskLowPercentage = try container.decodeIfPresent(Double.self, forKey: .riskLowPercentage) ?? 0
        riskNormalPercentage = try container.decodeIfPresent(Double.self, forKey: .riskNormalPercentage) ?? 0.10
        riskHighPercentage = try container.decodeIfPresent(Double.self, forKey: .riskHighPercentage) ?? 0.15
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hourlyRate, forKey: .hourlyRate)
        try container.encode(travelHourlyRate, forKey: .travelHourlyRate)
        try container.encode(kmRate, forKey: .kmRate)
        try container.encode(rushPercentage, forKey: .rushPercentage)
        try container.encode(difficultyNormalPercentage, forKey: .difficultyNormalPercentage)
        try container.encode(difficultyHardPercentage, forKey: .difficultyHardPercentage)
        try container.encode(difficultyVeryHardPercentage, forKey: .difficultyVeryHardPercentage)
        try container.encode(riskLowPercentage, forKey: .riskLowPercentage)
        try container.encode(riskNormalPercentage, forKey: .riskNormalPercentage)
        try container.encode(riskHighPercentage, forKey: .riskHighPercentage)
    }
}

struct CalculationInput: Codable, Equatable {
    var projectName: String = ""
    var materials: [MaterialLine] = [
        MaterialLine(name: "", cost: 0, markup: 0.40)
    ]
    var shipping: Double = 0
    var prepHours: Double = 0
    var installHours: Double = 0
    var installers: Int = 1
    var travelHours: Double = 0
    var kilometers: Double = 0
    var parkingToll: Double = 0
    var rental: Double = 0
    var otherDirectCosts: Double = 0
    var difficulty: Difficulty = .normal
    var risk: RiskLevel = .normal
    var rush: Bool = false
    var chosenPrice: Double = 0
    // Optioneel zodat oudere, al opgeslagen projecten (zonder deze velden) gewoon blijven laden.
    var vehicleBrand: String? = nil
    var vehicleModel: String? = nil
    var vehicleBodyType: String? = nil
    var vehicleYear: String? = nil
    // Optioneel (Optional-velden worden door Codable ook zonder aangepaste
    // init/encode probleemloos overgeslagen als ze in een ouder, al opgeslagen
    // project ontbreken) zodat de gekoppelde klant nu wél onderdeel is van het
    // project zelf — en dus meegaat bij opslaan, synchroniseren en op elk
    // apparaat weer verschijnt, in plaats van losse, niet-opgeslagen schermstatus.
    var linkedCustomerID: UUID? = nil
}

struct SavedProject: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var modifiedAt: Date
    var input: CalculationInput
    var settings: CalculatorSettings

    var displayName: String {
        let cleaned = input.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Naamloze calculatie" : cleaned
    }
}

struct CalculationResult {
    let materialCost: Double
    let materialCharged: Double
    let installHoursTotal: Double
    let prepLabor: Double
    let installLabor: Double
    let travelCharge: Double
    let kmCharge: Double
    let directExtras: Double
    let subtotal: Double
    let suggestedPrice: Double
    let directCostTotal: Double
    let amountAfterDirectCosts: Double
    let effectivePerWorkedHour: Double
    let chosenDifference: Double
}

func calculate(input: CalculationInput, settings: CalculatorSettings) -> CalculationResult {
    let materialCost = input.materials.reduce(0) { $0 + $1.cost }
    let materialCharged = input.materials.reduce(0) { $0 + $1.charged }
    let installHoursTotal = input.installHours * Double(max(input.installers, 1))
    let prepLabor = input.prepHours * settings.hourlyRate
    let installLabor = installHoursTotal * settings.hourlyRate
    let travelCharge = input.travelHours * settings.travelHourlyRate
    let kmCharge = input.kilometers * settings.kmRate
    let directExtras = input.shipping + input.parkingToll + input.rental + input.otherDirectCosts

    let subtotal = materialCharged + prepLabor + installLabor + travelCharge + kmCharge + directExtras
    let rush = input.rush ? settings.rushPercentage : 0
    let suggestedPrice = subtotal * input.difficulty.factor(in: settings) * (1 + input.risk.percentage(in: settings) + rush)

    let directCostTotal = materialCost + input.shipping + input.parkingToll + input.rental + input.otherDirectCosts + travelCharge + kmCharge
    let amountAfterDirectCosts = suggestedPrice - directCostTotal
    let workedHours = input.prepHours + installHoursTotal + input.travelHours
    let effectivePerWorkedHour = workedHours > 0 ? amountAfterDirectCosts / workedHours : 0
    let chosenDifference = input.chosenPrice - suggestedPrice

    return CalculationResult(
        materialCost: materialCost,
        materialCharged: materialCharged,
        installHoursTotal: installHoursTotal,
        prepLabor: prepLabor,
        installLabor: installLabor,
        travelCharge: travelCharge,
        kmCharge: kmCharge,
        directExtras: directExtras,
        subtotal: subtotal,
        suggestedPrice: suggestedPrice,
        directCostTotal: directCostTotal,
        amountAfterDirectCosts: amountAfterDirectCosts,
        effectivePerWorkedHour: effectivePerWorkedHour,
        chosenDifference: chosenDifference
    )
}
