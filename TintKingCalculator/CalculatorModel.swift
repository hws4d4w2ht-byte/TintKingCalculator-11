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
    var factor: Double {
        switch self {
        case .normal: return 1.00
        case .hard: return 1.10
        case .veryHard: return 1.20
        }
    }
}

enum RiskLevel: String, CaseIterable, Identifiable, Codable {
    case low = "Laag"
    case normal = "Normaal"
    case high = "Hoog"

    var id: String { rawValue }
    var percentage: Double {
        switch self {
        case .low: return 0.05
        case .normal: return 0.10
        case .high: return 0.15
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

struct CalculatorSettings: Codable, Equatable {
    var hourlyRate: Double = 75
    var travelHourlyRate: Double = 25
    var kmRate: Double = 0.35
    var rushPercentage: Double = 0.15
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
    let suggestedPrice = subtotal * input.difficulty.factor * (1 + input.risk.percentage + rush)

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
