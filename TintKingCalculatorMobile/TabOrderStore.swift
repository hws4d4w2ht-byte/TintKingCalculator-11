import Foundation

extension AppTab {
    /// Titel zoals die in de mobiele tabbalk staat — bij een paar tabs iets
    /// korter dan `title`, zodat de tekst in de tabbalk past. Ook gebruikt op
    /// het "Volgorde aanpassen"-scherm, zodat dat exact overeenkomt met wat
    /// je onderin de app ziet.
    var mobileTabTitle: String {
        switch self {
        case .montage: return "Offerte"
        case .tint: return "Tinten"
        case .roll: return "Rol"
        case .kozijn: return "Kozijnen"
        default: return title
        }
    }

    /// Icoon zoals dat in de mobiele tabbalk staat — bij Rol wijkt dit af van
    /// het icoon dat elders (Mac, snelkoppelingen op Home) gebruikt wordt.
    var mobileTabImage: String {
        switch self {
        case .roll: return "ruler"
        default: return systemImage
        }
    }
}

/// Onthoudt in welke volgorde de tabbladen onderin de mobiele app staan, zodat
/// je ze zelf kunt herschikken via het "Volgorde aanpassen"-scherm (te
/// bereiken vanaf Home). Puur een weergave-instelling per apparaat
/// (UserDefaults), geen iCloud-synchronisatie nodig.
final class TabOrderStore: ObservableObject {
    static let defaultOrder: [AppTab] = [
        .home, .montage, .tint, .dechrome, .producten, .aanvraag,
        .roll, .snijfolie, .meten, .prijslijst, .klanten, .bestellijst, .kozijn,
    ]

    @Published private(set) var order: [AppTab] = defaultOrder

    private let storageKey = "TintKing.MobileTabOrder.v1"

    init() {
        load()
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func resetToDefault() {
        order = Self.defaultOrder
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
