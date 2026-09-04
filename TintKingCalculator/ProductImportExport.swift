import Foundation

/// Import/export van de productenlijst als CSV-bestand — zelfde eenvoudige
/// stijl als de Prijslijst-import/export (zie PriceListImportExport.swift):
/// een backup die je in Excel of Numbers kunt openen/bewerken en later weer
/// kunt terugzetten.
extension ProductData {
    /// Nieuw CSV-formaat, met omschrijving en submenu's (varianten). Een
    /// product kan meerdere submenu-groepen hebben (bijv. Kleur, Maat); die
    /// worden binnen hun eigen kolom met "||" gescheiden, met per groep
    /// "Naam:optie1|optie2" (bijv. "Kleur:Rood|Zwart||Maat:Klein|Groot").
    func toCSV() -> String {
        var rows: [[String]] = [["Naam", "Categorie", "Omschrijving", "Varianten", "Prijs"]]
        for product in products {
            let variantsCell = product.variantGroups
                .map { group -> String in
                    let optionsText = group.options.map { option -> String in
                        option.priceDelta == 0 ? option.name : "\(option.name)@\(Self.csvNumber(option.priceDelta))"
                    }.joined(separator: "|")
                    return "\(group.name):\(optionsText)"
                }
                .joined(separator: "||")
            rows.append([
                product.name,
                product.category,
                product.description,
                variantsCell,
                Self.csvNumber(product.price)
            ])
        }
        let body = rows.map { row in row.map(Self.csvEscape).joined(separator: ";") }.joined(separator: "\r\n")
        // "sep=;" is een door Excel herkende hint zodat het bestand met
        // puntkomma-kolommen wordt geopend, ongeacht de regio-instelling van Excel.
        return "sep=;\r\n" + body
    }

    /// Zet een eerder geëxporteerd CSV-bestand weer om naar productdata. Geeft
    /// `nil` terug als het bestand geen enkele herkenbare regel bevat.
    ///
    /// Ondersteunt zowel het nieuwste formaat (Naam;Categorie;Omschrijving;
    /// Varianten;Prijs, met "Naam:opt1|opt2" per submenu-groep) als het
    /// oudere, eenvoudigere formaat (Naam;Categorie;Prijs) — zoals eerder al
    /// vanuit Moneybird geïmporteerde lijsten — zodat die bestanden gewoon
    /// blijven werken. Een varianten-cel zonder ":" (het allereerste, nog
    /// naamloze formaat) wordt als één groep "Variant" ingelezen.
    static func fromCSV(_ csv: String) -> ProductData? {
        var rows = Self.parseCSV(csv)
        guard !rows.isEmpty else { return nil }
        if let first = rows.first, let firstField = first.first, firstField.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("sep=") {
            rows.removeFirst()
        }
        if let first = rows.first, first.first?.trimmingCharacters(in: .whitespaces).lowercased() == "naam" {
            rows.removeFirst()
        }

        var products: [ProductItem] = []
        for row in rows {
            guard !row.isEmpty else { continue }
            let name = row[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let category = row.count >= 2 ? row[1].trimmingCharacters(in: .whitespaces) : ""

            let description: String
            let variantGroups: [ProductVariantGroup]
            let price: Double
            if row.count >= 5 {
                description = row[2].trimmingCharacters(in: .whitespaces)
                variantGroups = Self.parseVariantGroupsCell(row[3])
                price = Double(row[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            } else {
                description = ""
                variantGroups = []
                price = row.count >= 3 ? (Double(row[2].replacingOccurrences(of: ",", with: ".")) ?? 0) : 0
            }

            products.append(ProductItem(name: name, category: category, description: description, variantGroups: variantGroups, price: price))
        }
        guard !products.isEmpty else { return nil }
        return ProductData(products: products)
    }

    private static func parseVariantGroupsCell(_ cell: String) -> [ProductVariantGroup] {
        cell.components(separatedBy: "||").compactMap { segment in
            let trimmedSegment = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmedSegment.isEmpty else { return nil }
            let groupName: String
            let optionsText: String
            if let colonIndex = trimmedSegment.firstIndex(of: ":") {
                groupName = String(trimmedSegment[trimmedSegment.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                optionsText = String(trimmedSegment[trimmedSegment.index(after: colonIndex)...])
            } else {
                // Ouder, naamloos formaat: de hele cel is gewoon een lijst opties.
                groupName = "Variant"
                optionsText = trimmedSegment
            }
            let options: [ProductVariantOption] = optionsText.split(separator: "|").compactMap { rawToken in
                let token = rawToken.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { return nil }
                if let atIndex = token.lastIndex(of: "@") {
                    let namePart = String(token[token.startIndex..<atIndex]).trimmingCharacters(in: .whitespaces)
                    let pricePart = String(token[token.index(after: atIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ",", with: ".")
                    if !namePart.isEmpty, let price = Double(pricePart) {
                        return ProductVariantOption(name: namePart, priceDelta: price)
                    }
                }
                return ProductVariantOption(name: token, priceDelta: 0)
            }
            guard !groupName.isEmpty || !options.isEmpty else { return nil }
            return ProductVariantGroup(name: groupName, options: options)
        }
    }

    var importSummary: String {
        "\(products.count) product\(products.count == 1 ? "" : "en")"
    }

    private static func csvNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private static func csvEscape(_ field: String) -> String {
        if field.contains(";") || field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func detectDelimiter(_ text: String) -> Character {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased().hasPrefix("sep=") { continue }
            let semicolons = trimmed.filter { $0 == ";" }.count
            let commas = trimmed.filter { $0 == "," }.count
            return semicolons >= commas ? ";" : ","
        }
        return ";"
    }

    /// Kleine, robuuste CSV-parser die ook aanhalingstekens rond velden
    /// (met komma's/puntkomma's of newlines erin) correct afhandelt.
    private static func parseCSV(_ text: String) -> [[String]] {
        let delimiter = detectDelimiter(text)
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == delimiter {
                endField()
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case "\n", "\r", "\r\n":
                    endRow()
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }
}
