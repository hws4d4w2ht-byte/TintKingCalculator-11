import Foundation

/// Eén optie binnen een submenu-groep (bijv. "Rood" binnen "Kleur"), met een
/// optionele meerprijs (`priceDelta`) die bij de productprijs wordt opgeteld
/// zodra deze optie gekozen wordt bij het toevoegen aan een aanvraag.
struct ProductVariantOption: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var priceDelta: Double = 0

    private enum CodingKeys: String, CodingKey { case id, name, priceDelta }

    init(id: UUID = UUID(), name: String, priceDelta: Double = 0) {
        self.id = id
        self.name = name
        self.priceDelta = priceDelta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        priceDelta = try container.decodeIfPresent(Double.self, forKey: .priceDelta) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(priceDelta, forKey: .priceDelta)
    }
}

/// Eén "submenu" bij een product, bijv. "Kleur" met opties Rood/Zwart/Blauw,
/// of "Maat" met opties Klein/Groot. Een product kan meerdere van deze
/// groepen hebben, elk met hun eigen keuzemenu bij het toevoegen aan een
/// aanvraag. Elke optie kan een eigen meerprijs hebben.
///
/// `sharedGroupID` verwijst optioneel naar een gedeelde submenu-groep uit de
/// "Submenu configurator" (`ProductStore.sharedVariantGroups`). Is dit gezet,
/// dan gelden de actuele naam en opties van die gedeelde groep (zie
/// `ProductStore.resolvedGroup`) — een prijswijziging in de configurator werkt
/// dan meteen door bij alle producten die naar dezelfde groep verwijzen. De
/// eigen `name`/`options` hieronder blijven bewaard als laatst bekende kopie,
/// zodat een product blijft werken als de gedeelde groep ooit verwijderd wordt.
struct ProductVariantGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var options: [ProductVariantOption]
    var sharedGroupID: UUID? = nil

    private enum CodingKeys: String, CodingKey { case id, name, options, sharedGroupID }

    init(id: UUID = UUID(), name: String, options: [ProductVariantOption], sharedGroupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.options = options
        self.sharedGroupID = sharedGroupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        sharedGroupID = try container.decodeIfPresent(UUID.self, forKey: .sharedGroupID)
        if let opts = try? container.decode([ProductVariantOption].self, forKey: .options) {
            options = opts
        } else if let legacyOpts = try? container.decode([String].self, forKey: .options) {
            // Migratie vanaf vóór prijs-per-optie: platte tekstopties zonder meerprijs.
            options = legacyOpts.map { ProductVariantOption(name: $0) }
        } else {
            options = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(sharedGroupID, forKey: .sharedGroupID)
    }
}

/// Eén herbruikbare submenu-groep uit de "Submenu configurator": een naam
/// plus opties-met-prijs die je aan meerdere producten tegelijk kunt
/// koppelen. Verander je hier bijvoorbeeld de meerprijs van een kleur, dan
/// werkt dat meteen door bij alle producten die naar deze groep verwijzen —
/// je hoeft ze niet één voor één bij te werken.
struct SharedVariantGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var options: [ProductVariantOption]
}

/// Eén los product dat je verkoopt naast de calculators (bijv. rol folie,
/// lampenfolie, striping, schoonmaakmiddelen). Geen voorraadaantallen — dit is
/// bewust een eenvoudige productenlijst met prijzen, geen voorraadbeheer.
///
/// `description` is een vrije, langere omschrijving (zoals het
/// omschrijving-veld van een product in Moneybird) die als startpunt dient
/// voor de notitie zodra je dit product aan een aanvraag toevoegt.
/// `variantGroups` zijn de submenu's van dit product (bijv. Kleur, Maat) —
/// je kunt er meerdere hebben, elk met hun eigen keuzemenu bij het
/// toevoegen aan een aanvraag.
///
/// Een handgeschreven `init(from:)`/`encode(to:)` zorgt dat oudere,
/// opgeslagen producten.json-bestanden gewoon blijven inladen: bestanden van
/// vóór "omschrijving"/"varianten" krijgen description = "" en
/// variantGroups = [], en het allereerste, enkelvoudige "variants"-veld
/// (vóór submenu's met een eigen naam) wordt automatisch omgezet naar één
/// naamloze groep, zodat al ingevoerde varianten niet verloren gaan.
struct ProductItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var category: String
    var description: String = ""
    var variantGroups: [ProductVariantGroup] = []
    var price: Double

    init(id: UUID = UUID(), name: String, category: String, description: String = "", variantGroups: [ProductVariantGroup] = [], price: Double) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.variantGroups = variantGroups
        self.price = price
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, description, variants, variantGroups, price
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        price = try container.decode(Double.self, forKey: .price)

        if let groups = try container.decodeIfPresent([ProductVariantGroup].self, forKey: .variantGroups) {
            variantGroups = groups
        } else if let legacyVariants = try container.decodeIfPresent([String].self, forKey: .variants), !legacyVariants.isEmpty {
            // Migratie vanaf het allereerste, enkelvoudige variantenveld.
            variantGroups = [ProductVariantGroup(name: "Variant", options: legacyVariants.map { ProductVariantOption(name: $0) })]
        } else {
            variantGroups = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(description, forKey: .description)
        try container.encode(variantGroups, forKey: .variantGroups)
        try container.encode(price, forKey: .price)
    }
}

struct ProductData: Codable, Equatable {
    var products: [ProductItem] = []
    var sharedVariantGroups: [SharedVariantGroup] = []

    private enum CodingKeys: String, CodingKey { case products, sharedVariantGroups }

    init(products: [ProductItem] = [], sharedVariantGroups: [SharedVariantGroup] = []) {
        self.products = products
        self.sharedVariantGroups = sharedVariantGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        products = try container.decodeIfPresent([ProductItem].self, forKey: .products) ?? []
        sharedVariantGroups = try container.decodeIfPresent([SharedVariantGroup].self, forKey: .sharedVariantGroups) ?? []
    }
}

@MainActor
final class ProductStore: ObservableObject {
    @Published private(set) var data: ProductData
    @Published private(set) var lastError: String?

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("TintKingCalculator", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("products.json")
        data = ProductData()
        load()
    }

    func clearError() {
        lastError = nil
    }

    var products: [ProductItem] { data.products }

    /// Alle gebruikte categorieën, gesorteerd, zonder duplicaten — handig voor
    /// een suggestielijst bij het invoeren van een nieuw product.
    var categories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for product in data.products {
            let category = product.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty, !seen.contains(category) else { continue }
            seen.insert(category)
            result.append(category)
        }
        return result.sorted()
    }

    /// Ontleedt een door de gebruiker getypte, kommagescheiden tekst tot
    /// opties met eventueel een meerprijs, bijv. "Rood, Zwart:5, Blauw:7,50"
    /// → Rood (€0), Zwart (+€5), Blauw (+€7,50). Een dubbele punt zonder
    /// geldig bedrag erachter wordt gewoon als deel van de naam gezien.
    static func parseVariantOptions(_ text: String) -> [ProductVariantOption] {
        text.split(separator: ",").compactMap { rawToken in
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            if let colonIndex = token.lastIndex(of: ":") {
                let namePart = String(token[token.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let pricePart = String(token[token.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: ".")
                if !namePart.isEmpty, let price = Double(pricePart) {
                    return ProductVariantOption(name: namePart, priceDelta: price)
                }
            }
            return ProductVariantOption(name: token, priceDelta: 0)
        }
    }

    /// Zet opties terug om naar de kommagescheiden tekst die `parseVariantOptions`
    /// begrijpt, voor weergave in het tekstveld van de submenu-editor.
    static func formatVariantOptions(_ options: [ProductVariantOption]) -> String {
        options.map { option in
            option.priceDelta == 0 ? option.name : "\(option.name):\(Self.formatPrice(option.priceDelta))"
        }.joined(separator: ", ")
    }

    private static func formatPrice(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// Filtert lege opties (geen naam) eruit en trimt de rest op.
    static func cleanedOptions(_ options: [ProductVariantOption]) -> [ProductVariantOption] {
        options.compactMap { option in
            let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return ProductVariantOption(id: option.id, name: name, priceDelta: option.priceDelta)
        }
    }

    /// Filtert lege submenu's (geen naam én geen opties) eruit, en trimt
    /// verder alles op — bijv. na het bewerken in `variantGroupsEditor`. Een
    /// groep die aan een gedeelde configurator-groep gekoppeld is
    /// (`sharedGroupID`) blijft ongemoeid — de actuele opties daarvan komen
    /// toch uit de configurator (zie `resolvedGroup`).
    static func cleanedVariantGroups(_ groups: [ProductVariantGroup]) -> [ProductVariantGroup] {
        groups.compactMap { group in
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if group.sharedGroupID != nil {
                return ProductVariantGroup(id: group.id, name: name.isEmpty ? group.name : name, options: group.options, sharedGroupID: group.sharedGroupID)
            }
            let options = Self.cleanedOptions(group.options)
            guard !name.isEmpty || !options.isEmpty else { return nil }
            return ProductVariantGroup(id: group.id, name: name, options: options)
        }
    }

    /// Geeft de actuele naam en opties voor een submenu-groep van een
    /// product: als de groep aan een gedeelde configurator-groep gekoppeld is
    /// (`sharedGroupID`) en die nog bestaat, gelden die actuele naam/opties —
    /// zo werkt een prijswijziging in de configurator meteen door. Bestaat de
    /// gedeelde groep niet meer, dan valt dit terug op de eigen, laatst
    /// bekende naam/opties van het product.
    func resolvedGroup(for group: ProductVariantGroup) -> ProductVariantGroup {
        guard let sharedID = group.sharedGroupID,
              let shared = data.sharedVariantGroups.first(where: { $0.id == sharedID }) else {
            return group
        }
        return ProductVariantGroup(id: group.id, name: shared.name, options: shared.options, sharedGroupID: sharedID)
    }

    var sharedVariantGroups: [SharedVariantGroup] { data.sharedVariantGroups }

    /// Voegt een nieuwe gedeelde submenu-groep toe aan de configurator, los
    /// van een specifiek product, zodat je 'm daarna aan meerdere producten
    /// kunt koppelen.
    func addSharedVariantGroup(name: String, options: [ProductVariantOption]) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        data.sharedVariantGroups.append(SharedVariantGroup(name: cleanName, options: Self.cleanedOptions(options)))
        persist()
    }

    /// Werkt een gedeelde submenu-groep bij — bijv. de meerprijs van een
    /// kleur — zodat dit meteen doorwerkt bij alle producten die ernaar
    /// verwijzen (zie `resolvedGroup`).
    func updateSharedVariantGroup(id: UUID, name: String, options: [ProductVariantOption]) {
        guard let index = data.sharedVariantGroups.firstIndex(where: { $0.id == id }) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        data.sharedVariantGroups[index].name = cleanName
        data.sharedVariantGroups[index].options = Self.cleanedOptions(options)
        persist()
    }

    func deleteSharedVariantGroup(id: UUID) {
        data.sharedVariantGroups.removeAll { $0.id == id }
        persist()
    }

    func add(name: String, category: String, description: String = "", variantGroups: [ProductVariantGroup] = [], price: Double) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        data.products.append(ProductItem(name: cleanName, category: cleanCategory, description: cleanDescription, variantGroups: Self.cleanedVariantGroups(variantGroups), price: price))
        persist()
    }

    func update(id: UUID, name: String, category: String, description: String = "", variantGroups: [ProductVariantGroup] = [], price: Double) {
        guard let index = data.products.firstIndex(where: { $0.id == id }) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        data.products[index].name = cleanName
        data.products[index].category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        data.products[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        data.products[index].variantGroups = Self.cleanedVariantGroups(variantGroups)
        data.products[index].price = price
        persist()
    }

    func delete(id: UUID) {
        data.products.removeAll { $0.id == id }
        persist()
    }

    /// Vervangt de volledige productenlijst door geïmporteerde data (bijv. na
    /// een CSV-import).
    func replaceAll(with newData: ProductData) {
        data = newData
        persist()
    }

    /// Voegt geïmporteerde producten toe aan de bestaande lijst, i.p.v. de hele
    /// lijst te vervangen.
    func appendImported(_ newData: ProductData) {
        data.products.append(contentsOf: newData.products)
        persist()
    }

    // MARK: - Persistentie (lokaal, geen iCloud — bewust eenvoudig gehouden)

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            data = try JSONDecoder().decode(ProductData.self, from: raw)
            lastError = nil
        } catch {
            lastError = "Producten konden niet worden geladen: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let raw = try encoder.encode(data)
            try raw.write(to: fileURL, options: [.atomic])
            lastError = nil
        } catch {
            lastError = "Producten konden niet worden opgeslagen: \(error.localizedDescription)"
        }
    }
}
