import SwiftUI
import UniformTypeIdentifiers

/// Import/export van de volledige prijslijst als CSV-bestand: een back-up die je
/// in Excel of Numbers kunt openen/bewerken en later weer kunt terugzetten,
/// bijvoorbeeld als je alle prijzen door een crash kwijt bent geraakt.
///
/// We gebruiken bewust CSV (en niet een echt .xlsx-bestand): Excel opent en
/// bewerkt CSV-bestanden gewoon, en zo blijft de app volledig op eigen kracht
/// werken zonder externe library. Bewaar/importeer het bestand als CSV (dus
/// niet als "echte" .xlsx opslaan) om alles goed te laten terugkomen.
extension PriceListData {
    /// Bouwt één CSV-bestand met alle prijslijst-onderdelen én de
    /// Snijfolie-instellingen, zodat er precies genoeg in staat om de hele
    /// prijslijst weer terug te zetten.
    func toCSV() -> String {
        var rows: [[String]] = [["Sectie", "Naam", "Prijs", "Categorie"]]

        for entry in tintBasePackages {
            rows.append(["TintBasis", entry.name, Self.csvNumber(entry.price), entry.category])
        }
        for entry in tintExtras {
            rows.append(["TintExtra", entry.name, Self.csvNumber(entry.price), entry.category])
        }
        for entry in dechromeParts {
            rows.append(["Ontchromen", entry.name, Self.csvNumber(entry.price), entry.category])
        }
        for entry in cutFoilMaterials ?? [] {
            rows.append(["SnijfolieMateriaal", entry.name, Self.csvNumber(entry.price), entry.category])
        }

        for (name, value) in [
            ("Snijfolie rolbreedte (cm)", cutFoilRollWidthCm ?? 122),
            ("Snijfolie marge (cm)", cutFoilMarginCm ?? 8),
            ("Snijfolie opstartkosten (EUR)", cutFoilStartupCost ?? 25),
            ("Snijfolie arbeidsprijs per m2 (EUR)", cutFoilLaborPricePerM2 ?? 20.0),
            ("Snijfolie minimumprijs per sticker (EUR)", cutFoilMinimumPricePerPiece ?? 1.00),
            ("Snijfolie factor Eenvoudig", cutFoilSimpleMultiplier ?? 1.0),
            ("Snijfolie factor Gemiddeld", cutFoilMediumMultiplier ?? 2.2),
            ("Snijfolie factor Complex", cutFoilComplexMultiplier ?? 3.2)
        ] {
            rows.append(["Instelling", name, Self.csvNumber(value), ""])
        }

        let body = rows.map { row in row.map(Self.csvEscape).joined(separator: ";") }.joined(separator: "\r\n")
        // "sep=;" is een door Excel herkende hint die bovenaan een CSV-bestand mag
        // staan, zodat het bestand met puntkomma-kolommen wordt geopend ongeacht de
        // regio-instelling van Excel (in Nederland is de standaardlijstscheiding
        // een puntkomma, omdat een komma al de decimaaltekens scheidt). Zonder deze
        // hint plakt Excel bij een Nederlandse instelling anders alles in kolom A.
        return "sep=;\r\n" + body
    }

    /// Zet een eerder geëxporteerd CSV-bestand weer om naar prijslijst-data.
    /// Geeft `nil` terug als het bestand geen enkele herkenbare regel bevat.
    static func fromCSV(_ csv: String) -> PriceListData? {
        var rows = Self.parseCSV(csv)
        guard !rows.isEmpty else { return nil }
        // Sla de Excel-hint "sep=;" over als die bovenaan staat (zie toCSV()).
        if let first = rows.first, let firstField = first.first, firstField.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("sep=") {
            rows.removeFirst()
        }
        if let first = rows.first, first.first?.lowercased() == "sectie" {
            rows.removeFirst()
        }

        var tintBase: [PriceListEntry] = []
        var tintExtras: [PriceListEntry] = []
        var dechrome: [PriceListEntry] = []
        var cutFoilMaterials: [PriceListEntry] = []
        var settings: [String: Double] = [:]

        for row in rows {
            guard row.count >= 3 else { continue }
            // Case-ongevoelig en spaties genegeerd, zodat handmatig toegevoegde
            // rijen in Excel (bijv. "ontchromen" i.p.v. "Ontchromen") ook werken.
            let section = row[0].trimmingCharacters(in: .whitespaces).lowercased()
            let name = row[1].trimmingCharacters(in: .whitespaces)
            let price = Double(row[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            let category = row.count >= 4 ? row[3].trimmingCharacters(in: .whitespaces) : ""
            guard !name.isEmpty else { continue }

            switch section {
            case "tintbasis":
                tintBase.append(PriceListEntry(name: name, price: price, category: category))
            case "tintextra":
                tintExtras.append(PriceListEntry(name: name, price: price, category: category))
            case "ontchromen":
                dechrome.append(PriceListEntry(name: name, price: price, category: category))
            case "snijfoliemateriaal":
                cutFoilMaterials.append(PriceListEntry(name: name, price: price, category: category))
            case "instelling":
                settings[name] = price
            default:
                continue
            }
        }

        guard !tintBase.isEmpty || !tintExtras.isEmpty || !dechrome.isEmpty || !cutFoilMaterials.isEmpty else {
            return nil
        }

        var data = PriceListData(
            tintBasePackages: tintBase,
            tintExtras: tintExtras,
            dechromeParts: dechrome
        )
        data.cutFoilMaterials = cutFoilMaterials.isEmpty ? nil : cutFoilMaterials
        data.cutFoilRollWidthCm = settings["Snijfolie rolbreedte (cm)"]
        data.cutFoilMarginCm = settings["Snijfolie marge (cm)"]
        data.cutFoilStartupCost = settings["Snijfolie opstartkosten (EUR)"]
        data.cutFoilLaborPricePerM2 = settings["Snijfolie arbeidsprijs per m2 (EUR)"]
        data.cutFoilMinimumPricePerPiece = settings["Snijfolie minimumprijs per sticker (EUR)"]
        data.cutFoilSimpleMultiplier = settings["Snijfolie factor Eenvoudig"]
        data.cutFoilMediumMultiplier = settings["Snijfolie factor Gemiddeld"]
        data.cutFoilComplexMultiplier = settings["Snijfolie factor Complex"]
        return data
    }

    /// Telt hoeveel items van elk type een geïmporteerd bestand bevat, voor de
    /// bevestigingsvraag voordat de huidige prijslijst wordt overschreven.
    var importSummary: String {
        var parts: [String] = []
        if !tintBasePackages.isEmpty { parts.append("\(tintBasePackages.count) tint-basispakketten") }
        if !tintExtras.isEmpty { parts.append("\(tintExtras.count) tint-extra's") }
        if !dechromeParts.isEmpty { parts.append("\(dechromeParts.count) ontchroom-onderdelen") }
        if let materials = cutFoilMaterials, !materials.isEmpty { parts.append("\(materials.count) snijfolie-materialen") }
        return parts.joined(separator: ", ")
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

    /// Bepaalt of het bestand puntkomma's of komma's als scheidingsteken gebruikt,
    /// zodat zowel nieuwe (";") als oudere (",") exports correct worden gelezen.
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

/// Bestandswrapper voor het exporteren/importeren van de prijslijst als CSV via
/// de standaard SwiftUI bestandskiezer (werkt zo op zowel Mac als mobiel).
struct PriceListCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var csv: String

    init(csv: String) {
        self.csv = csv
    }

    init(configuration: ReadConfiguration) throws {
        guard
            let data = configuration.file.regularFileContents,
            let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.csv = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(csv.utf8))
    }
}
