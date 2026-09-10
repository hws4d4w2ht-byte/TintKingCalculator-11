import Foundation

extension AppTab {
    /// Titel zoals die in de Mac-tabbalk staat. Komt overeen met de teksten
    /// die voorheen los in ContentView.swift bij elke tab stonden.
    var desktopTabTitle: String {
        switch self {
        case .home: return "Home"
        case .montage: return "Montage"
        case .tint: return "Tinten"
        case .dechrome: return "Ontchromen"
        case .roll: return "Rol"
        case .snijfolie: return "Snijfolie"
        case .meten: return "Meten"
        case .producten: return "Producten"
        case .aanvraag: return "Aanvraag"
        case .prijslijst: return "Prijzen"
        case .klanten: return "Klanten"
        case .bestellijst: return "Bestellen"
        case .kozijn: return "Kozijnen"
        }
    }

    /// Icoon zoals dat in de Mac-tabbalk staat.
    var desktopTabImage: String {
        switch self {
        case .home: return "house"
        case .montage: return "doc.text"
        case .tint: return "car.side"
        case .dechrome: return "sparkles"
        case .roll: return "cylinder"
        case .snijfolie: return "scissors"
        case .meten: return "ruler"
        case .producten: return "shippingbox"
        case .aanvraag: return "cart"
        case .prijslijst: return "list.bullet.rectangle"
        case .klanten: return "person.text.rectangle"
        case .bestellijst: return "list.clipboard"
        case .kozijn: return "square.dashed"
        }
    }
}

/// Onthoudt in welke volgorde de tabbladen in de Mac-tabbalk staan, zodat je
/// ze zelf kunt herschikken via het "Volgorde aanpassen"-scherm (te bereiken
/// vanaf Home) — net als op mobiel. Puur een weergave-instelling per
/// apparaat (UserDefaults), geen iCloud-synchronisatie nodig.
///
/// Bewust GEEN losse move-functie die live op `order` werkt: de bovenste
/// tabbalk in ContentView gebruikt dezelfde `order` en is de hele tijd
/// gemonteerd. Als je tijdens het slepen in het volgorde-scherm `order`
/// telkens live zou bijwerken, gaat die bovenste tabbalk bij elke
/// tussenstap opnieuw schikken — en dat laat op macOS soms een dubbel/spook-
/// tabblad achter. Daarom werkt het volgorde-scherm op een eigen kopie en
/// wordt hier pas één keer, via `commit(_:)`, de definitieve volgorde
/// doorgevoerd zodra je het scherm verlaat.
final class DesktopTabOrderStore: ObservableObject {
    static let defaultOrder: [AppTab] = [
        .home, .montage, .tint, .dechrome, .roll, .snijfolie,
        .meten, .producten, .aanvraag, .prijslijst, .klanten, .bestellijst, .kozijn,
    ]

    @Published private(set) var order: [AppTab] = defaultOrder

    private let storageKey = "TintKing.DesktopTabOrder.v1"

    init() {
        load()
    }

    /// Vervangt de volgorde in één keer. Wordt aangeroepen zodra het
    /// volgorde-scherm sluit, niet tijdens het slepen zelf.
    func commit(_ newOrder: [AppTab]) {
        guard newOrder != order else { return }
        order = newOrder
        persist()
    }

    private func load() {
        guard let stored = UserDefaults.standard.array(forKey: storageKey) as? [String] else { return }
        var resolved = stored.compactMap { AppTab(rawValue: $0) }
        // Tabbladen die nog niet in de opgeslagen volgorde zitten (bijvoorbeeld
        // na een app-update met een nieuw tabblad) worden achteraan toegevoegd,
        // zodat ze niet onzichtbaar worden.
        for tab in Self.defaultOrder where !resolved.contains(tab) {
            resolved.append(tab)
        }
        guard !resolved.isEmpty else { return }
        order = resolved
    }

    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: storageKey)
    }
}
