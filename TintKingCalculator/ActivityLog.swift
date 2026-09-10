import Foundation

/// Alle tabbladen in de app. Gebruikt om vanuit de Home-tab naar een ander
/// tabblad te kunnen springen (en om te onthouden bij welk tabblad een
/// activiteit hoort). Mac en mobiel gebruiken niet exact dezelfde volgorde of
/// namen voor hun tabs, maar wel dezelfde gevallen hier.
enum AppTab: String, Codable, CaseIterable, Hashable {
    case home
    case montage
    case tint
    case dechrome
    case roll
    case snijfolie
    case meten
    case producten
    case prijslijst
    case aanvraag
    case klanten
    case bestellijst
    case kozijn

    var title: String {
        switch self {
        case .home: return "Home"
        case .montage: return "Offerte / montage"
        case .tint: return "Ramen tinten"
        case .dechrome: return "Ontchromen"
        case .roll: return "Rolcalculator"
        case .snijfolie: return "Snijfolie"
        case .meten: return "Meten"
        case .producten: return "Producten"
        case .prijslijst: return "Prijslijst"
        case .aanvraag: return "Aanvraag"
        case .klanten: return "Klanten"
        case .bestellijst: return "Bestellijst"
        case .kozijn: return "Kozijn wrappen"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .montage: return "doc.text"
        case .tint: return "car.side"
        case .dechrome: return "sparkles"
        case .roll: return "cylinder"
        case .snijfolie: return "scissors"
        case .meten: return "ruler"
        case .producten: return "shippingbox"
        case .prijslijst: return "list.bullet.rectangle"
        case .aanvraag: return "cart"
        case .klanten: return "person.text.rectangle"
        case .bestellijst: return "list.clipboard"
        case .kozijn: return "square.dashed"
        }
    }
}

/// Eén regel in het activiteitenoverzicht op de Home-tab: een korte
/// beschrijving van iets dat net gebeurd is. `tab` (en eventueel
/// `customerID`) bepalen waar je naartoe springt als je erop tikt.
struct ActivityEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var text: String
    var systemImage: String = "clock"
    var tab: AppTab?
    var customerID: UUID?
}

/// Houdt de laatste handelingen in de app bij (nieuwe klant, notitie
/// toegevoegd, offerte verstuurd, ...) voor op de Home-tab. Bewust een
/// singleton, net als CloudSyncCenter — zo kan elk scherm hier meteen naar
/// loggen zonder dat de store overal doorgegeven hoeft te worden. Lokaal
/// opgeslagen (UserDefaults); puur een gemaksoverzicht per apparaat, niet
/// gesynchroniseerd via iCloud.
@MainActor
final class ActivityLogStore: ObservableObject {
    static let shared = ActivityLogStore()

    @Published private(set) var entries: [ActivityEntry] = []

    private let storageKey = "TintKing.ActivityLog.v1"
    private let maxEntries = 40

    private init() {
        load()
    }

    func log(_ text: String, systemImage: String = "clock", tab: AppTab? = nil, customerID: UUID? = nil) {
        var updated = entries
        updated.insert(ActivityEntry(text: text, systemImage: systemImage, tab: tab, customerID: customerID), at: 0)
        if updated.count > maxEntries {
            updated.removeLast(updated.count - maxEntries)
        }
        entries = updated
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
