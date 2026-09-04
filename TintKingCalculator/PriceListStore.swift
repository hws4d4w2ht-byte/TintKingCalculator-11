import Foundation
import CloudKit

struct PriceListEntry: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var price: Double
    var category: String
}

struct PriceListData: Codable, Equatable {
    var tintBasePackages: [PriceListEntry]
    var tintExtras: [PriceListEntry]
    var dechromeParts: [PriceListEntry]
    /// Materialen voor de Snijfolie-calculator (naam + prijs per m²). Optioneel
    /// gehouden zodat oudere lokale/iCloud-prijslijsten (van vóór deze functie)
    /// gewoon blijven decoderen.
    var cutFoilMaterials: [PriceListEntry]? = nil

    /// Instellingen voor de Snijfolie-calculator (rolbreedte, marge, kosten).
    /// Allemaal optioneel met een standaardwaarde bij gebruik, zodat oudere
    /// prijslijsten gewoon blijven decoderen.
    var cutFoilRollWidthCm: Double? = nil
    var cutFoilMarginCm: Double? = nil
    var cutFoilStartupCost: Double? = nil
    var cutFoilLaborPricePerM2: Double? = nil
    var cutFoilMinimumPricePerPiece: Double? = nil

    /// Complexiteitsfactoren voor de arbeidskosten (vermenigvuldigen de
    /// arbeidsprijs per m² bij Eenvoudig/Gemiddeld/Complex). Optioneel met
    /// standaardwaarden 1.0/1.3/1.6, zodat oudere prijslijsten blijven decoderen.
    var cutFoilSimpleMultiplier: Double? = nil
    var cutFoilMediumMultiplier: Double? = nil
    var cutFoilComplexMultiplier: Double? = nil

    var modifiedAt: Date? = nil
}

@MainActor
final class PriceListStore: ObservableObject {
    @Published private(set) var data: PriceListData
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let fileURL: URL
    private static let recordType = "PriceList"
    private static let recordName = "main"

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("TintKingCalculator", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("pricelist.json")
        data = Self.defaultData
        load()
        Task { await syncWithCloud() }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Tint basispakketten

    func addTintBasePackage(name: String, price: Double, category: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !data.tintBasePackages.contains(where: { $0.name == clean }) else { return }
        data.tintBasePackages.append(PriceListEntry(name: clean, price: price, category: category))
        persist()
    }

    func updateTintBasePackage(name: String, price: Double, category: String) {
        guard let index = data.tintBasePackages.firstIndex(where: { $0.name == name }) else { return }
        data.tintBasePackages[index].price = price
        data.tintBasePackages[index].category = category
        persist()
    }

    func deleteTintBasePackage(name: String) {
        guard name != "Geen basispakket" else { return }
        data.tintBasePackages.removeAll { $0.name == name }
        persist()
    }

    func resetTintBasePackagesToDefault() {
        data.tintBasePackages = Self.defaultData.tintBasePackages
        persist()
    }

    // MARK: - Tint extra's

    func addTintExtra(name: String, price: Double, category: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !data.tintExtras.contains(where: { $0.name == clean }) else { return }
        data.tintExtras.append(PriceListEntry(name: clean, price: price, category: category))
        persist()
    }

    func updateTintExtra(name: String, price: Double, category: String) {
        guard let index = data.tintExtras.firstIndex(where: { $0.name == name }) else { return }
        data.tintExtras[index].price = price
        data.tintExtras[index].category = category
        persist()
    }

    func deleteTintExtra(name: String) {
        data.tintExtras.removeAll { $0.name == name }
        persist()
    }

    func resetTintExtrasToDefault() {
        data.tintExtras = Self.defaultData.tintExtras
        persist()
    }

    // MARK: - Ontchromen onderdelen

    func addDechromePart(name: String, price: Double) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !data.dechromeParts.contains(where: { $0.name == clean }) else { return }
        data.dechromeParts.append(PriceListEntry(name: clean, price: price, category: ""))
        persist()
    }

    func updateDechromePart(name: String, price: Double) {
        guard let index = data.dechromeParts.firstIndex(where: { $0.name == name }) else { return }
        data.dechromeParts[index].price = price
        persist()
    }

    func deleteDechromePart(name: String) {
        data.dechromeParts.removeAll { $0.name == name }
        persist()
    }

    func resetDechromePartsToDefault() {
        data.dechromeParts = Self.defaultData.dechromeParts
        persist()
    }

    // MARK: - Snijfolie materialen

    func addCutFoilMaterial(name: String, price: Double) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var materials = data.cutFoilMaterials ?? []
        guard !materials.contains(where: { $0.name == clean }) else { return }
        materials.append(PriceListEntry(name: clean, price: price, category: ""))
        data.cutFoilMaterials = materials
        persist()
    }

    func updateCutFoilMaterial(name: String, price: Double) {
        guard var materials = data.cutFoilMaterials,
              let index = materials.firstIndex(where: { $0.name == name }) else { return }
        materials[index].price = price
        data.cutFoilMaterials = materials
        persist()
    }

    func deleteCutFoilMaterial(name: String) {
        guard var materials = data.cutFoilMaterials else { return }
        materials.removeAll { $0.name == name }
        data.cutFoilMaterials = materials
        persist()
    }

    func resetCutFoilMaterialsToDefault() {
        data.cutFoilMaterials = Self.defaultData.cutFoilMaterials
        persist()
    }

    // MARK: - Snijfolie instellingen

    var cutFoilRollWidthCm: Double { data.cutFoilRollWidthCm ?? 122 }
    var cutFoilMarginCm: Double { data.cutFoilMarginCm ?? 8 }
    var cutFoilStartupCost: Double { data.cutFoilStartupCost ?? 25 }
    var cutFoilLaborPricePerM2: Double { data.cutFoilLaborPricePerM2 ?? 20.0 }
    var cutFoilMinimumPricePerPiece: Double { data.cutFoilMinimumPricePerPiece ?? 1.00 }
    var cutFoilSimpleMultiplier: Double { data.cutFoilSimpleMultiplier ?? 1.0 }
    var cutFoilMediumMultiplier: Double { data.cutFoilMediumMultiplier ?? 2.2 }
    var cutFoilComplexMultiplier: Double { data.cutFoilComplexMultiplier ?? 3.2 }

    /// Geeft de ingestelde complexiteitsfactor voor een gegeven complexiteit,
    /// zodat de rest van de app niet met de losse velden hoeft te werken.
    func cutFoilMultiplier(for complexity: CutComplexity) -> Double {
        switch complexity {
        case .simple: return cutFoilSimpleMultiplier
        case .medium: return cutFoilMediumMultiplier
        case .complex: return cutFoilComplexMultiplier
        }
    }

    func updateCutFoilSettings(
        rollWidthCm: Double,
        marginCm: Double,
        startupCost: Double,
        laborPricePerM2: Double,
        minimumPricePerPiece: Double,
        simpleMultiplier: Double,
        mediumMultiplier: Double,
        complexMultiplier: Double
    ) {
        data.cutFoilRollWidthCm = rollWidthCm
        data.cutFoilMarginCm = marginCm
        data.cutFoilStartupCost = startupCost
        data.cutFoilLaborPricePerM2 = laborPricePerM2
        data.cutFoilMinimumPricePerPiece = minimumPricePerPiece
        data.cutFoilSimpleMultiplier = simpleMultiplier
        data.cutFoilMediumMultiplier = mediumMultiplier
        data.cutFoilComplexMultiplier = complexMultiplier
        persist()
    }

    // MARK: - Import / export (back-up)

    /// Vervangt de volledige prijslijst door geïmporteerde data (bijv. na een
    /// CSV-import) en slaat direct op, zowel lokaal als (indien beschikbaar) in
    /// iCloud.
    func replaceAll(with newData: PriceListData) {
        data = newData
        persist()
    }

    // MARK: - Persistentie

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            data = try JSONDecoder().decode(PriceListData.self, from: raw)
            lastError = nil
        } catch {
            lastError = "Prijslijst kon niet worden geladen: \(error.localizedDescription)"
        }
    }

    /// Slaat lokaal op, werkt de wijzigingsdatum bij, en stuurt de nieuwe prijslijst
    /// naar iCloud. Alle bewerkmethodes hierboven roepen deze ene plek aan.
    private func persist() {
        data.modifiedAt = Date()
        persistLocally()
        Task { await pushToCloud() }
    }

    private func persistLocally() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let raw = try encoder.encode(data)
            try raw.write(to: fileURL, options: [.atomic])
            lastError = nil
        } catch {
            lastError = "Prijslijst kon niet worden opgeslagen: \(error.localizedDescription)"
        }
    }

    // MARK: - iCloud-synchronisatie
    //
    // De prijslijst wordt als één geheel gesynchroniseerd (één CloudKit-record):
    // wie het laatst heeft gewijzigd, wint. Dat is bewust simpel gehouden — een
    // prijslijst wordt zelden op twee apparaten tegelijk aangepast.

    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        let records = await CloudSyncCenter.shared.fetchAllRecords(recordType: Self.recordType)
        if let remoteData = records.first(where: { $0.recordID.recordName == Self.recordName }).flatMap(PriceListData.init(record:)) {
            let remoteModified = remoteData.modifiedAt ?? .distantPast
            let localModified = data.modifiedAt ?? .distantPast
            if remoteModified > localModified {
                data = remoteData
                persistLocally()
            } else if localModified > remoteModified {
                await pushToCloud()
            }
        } else {
            // Nog niets in de cloud: onze lokale prijslijst is de eerste die gedeeld wordt.
            await pushToCloud()
        }

        lastSyncedAt = Date()
    }

    private func pushToCloud() async {
        let record = data.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID, recordName: Self.recordName, recordType: Self.recordType)
        _ = await CloudSyncCenter.shared.save(records: [record])
    }

    // MARK: - Standaardprijzen (identiek aan de oorspronkelijke ingebouwde lijsten)

    static let defaultData = PriceListData(
        tintBasePackages: [
            PriceListEntry(name: "Geen basispakket", price: 0, category: "Los samenstellen"),
            PriceListEntry(name: "B-Stijl Hatchback (3 deuren)", price: 160, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl Hatchback (5 deuren)", price: 220, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl Sedan", price: 240, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl Station", price: 260, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl SUV / Crossover", price: 260, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl SUV groot", price: 280, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl Coupe", price: 220, category: "B-Stijl"),
            PriceListEntry(name: "B-Stijl Pick-up", price: 220, category: "B-Stijl"),
            PriceListEntry(name: "A-Stijl Hatchback (3 deuren)", price: 280, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl Hatchback (5 deuren)", price: 340, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl Sedan", price: 360, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl Station", price: 380, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl SUV / Crossover", price: 380, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl SUV groot", price: 400, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl Coupe", price: 340, category: "A-Stijl"),
            PriceListEntry(name: "A-Stijl Pick-up", price: 340, category: "A-Stijl"),
            PriceListEntry(name: "Tesla Model 3 vanaf de B-stijl", price: 350, category: "Merkspecifiek"),
            PriceListEntry(name: "Tesla Model 3 vanaf de A-stijl", price: 470, category: "Merkspecifiek")
        ],
        tintExtras: [
            PriceListEntry(name: "Voorruit tinten", price: 160, category: "Losse ruit"),
            PriceListEntry(name: "Voorruit Chameleon folie", price: 240, category: "Losse ruit"),
            PriceListEntry(name: "Raamband / Zonneband tinten", price: 80, category: "Losse ruit"),
            PriceListEntry(name: "Driehoekruit tinten", price: 20, category: "Losse ruit"),
            PriceListEntry(name: "Voorportier tinten", price: 60, category: "Losse ruit"),
            PriceListEntry(name: "Driehoekruit + voorportier tinten", price: 80, category: "Losse ruit"),
            PriceListEntry(name: "Achterportier tinten", price: 60, category: "Losse ruit"),
            PriceListEntry(name: "Achterportier + driehoek achterruit tinten", price: 80, category: "Losse ruit"),
            PriceListEntry(name: "Zijruit vast kleiner dan 50 cm tinten", price: 40, category: "Losse ruit"),
            PriceListEntry(name: "Zijruit vast groter dan 50 cm tinten", price: 50, category: "Losse ruit"),
            PriceListEntry(name: "Achterklep station/hatchback dubbele deur tinten", price: 100, category: "Losse ruit"),
            PriceListEntry(name: "Achterruit Sedan of Coupe tinten", price: 140, category: "Losse ruit"),
            PriceListEntry(name: "Werkbus achterruit", price: 120, category: "Werkbus"),
            PriceListEntry(name: "Werkbus zijruiten schuifdeuren", price: 50, category: "Werkbus")
        ],
        dechromeParts: [
            PriceListEntry(name: "Achter skirt", price: 160, category: ""),
            PriceListEntry(name: "Achterbumper", price: 160, category: ""),
            PriceListEntry(name: "Achterklep", price: 40, category: ""),
            PriceListEntry(name: "Beltline Ontchromen mini", price: 240, category: ""),
            PriceListEntry(name: "Dakdrails Ontchromen", price: 200, category: ""),
            PriceListEntry(name: "Deurstrips", price: 80, category: ""),
            PriceListEntry(name: "Diffuser", price: 120, category: ""),
            PriceListEntry(name: "Dorpels", price: 120, category: ""),
            PriceListEntry(name: "Grill omlijsting Ontchromen", price: 100, category: ""),
            PriceListEntry(name: "Grill ontchromen", price: 160, category: ""),
            PriceListEntry(name: "Handgrepen Ontchromen", price: 100, category: ""),
            PriceListEntry(name: "Logo achter", price: 50, category: ""),
            PriceListEntry(name: "Logo pakket", price: 200, category: ""),
            PriceListEntry(name: "Logo voor", price: 50, category: ""),
            PriceListEntry(name: "Raamlijsten Ontchromen", price: 250, category: ""),
            PriceListEntry(name: "Spiegels", price: 120, category: ""),
            PriceListEntry(name: "Spoiler", price: 100, category: ""),
            PriceListEntry(name: "Uitlaat tips Ontchromen", price: 80, category: ""),
            PriceListEntry(name: "Voorbumper", price: 160, category: ""),
            PriceListEntry(name: "Voorskirt", price: 120, category: ""),
            PriceListEntry(name: "Zijschermen / spatbord", price: 60, category: ""),
            PriceListEntry(name: "logo audi voor", price: 95, category: ""),
            PriceListEntry(name: "logo audi achter", price: 95, category: ""),
            PriceListEntry(name: "mini koplamp ringen", price: 60, category: ""),
            PriceListEntry(name: "mini achterlichten ringen", price: 60, category: "")
        ],
        cutFoilMaterials: [
            PriceListEntry(name: "Standaard snijfolie", price: 25, category: "")
        ]
    )
}

// MARK: - CloudKit-mapping

private extension PriceListData {
    func toCKRecord(zoneID: CKRecordZone.ID, recordName: String, recordType: String) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["modifiedAt"] = (modifiedAt ?? Date()) as NSDate
        if let d = try? JSONEncoder().encode(tintBasePackages), let s = String(data: d, encoding: .utf8) {
            record["tintBasePackagesJSON"] = s as NSString
        }
        if let d = try? JSONEncoder().encode(tintExtras), let s = String(data: d, encoding: .utf8) {
            record["tintExtrasJSON"] = s as NSString
        }
        if let d = try? JSONEncoder().encode(dechromeParts), let s = String(data: d, encoding: .utf8) {
            record["dechromePartsJSON"] = s as NSString
        }
        if let materials = cutFoilMaterials, let d = try? JSONEncoder().encode(materials), let s = String(data: d, encoding: .utf8) {
            record["cutFoilMaterialsJSON"] = s as NSString
        }
        if let v = cutFoilRollWidthCm { record["cutFoilRollWidthCm"] = v as NSNumber }
        if let v = cutFoilMarginCm { record["cutFoilMarginCm"] = v as NSNumber }
        if let v = cutFoilStartupCost { record["cutFoilStartupCost"] = v as NSNumber }
        if let v = cutFoilLaborPricePerM2 { record["cutFoilLaborPricePerM2"] = v as NSNumber }
        if let v = cutFoilMinimumPricePerPiece { record["cutFoilMinimumPricePerPiece"] = v as NSNumber }
        if let v = cutFoilSimpleMultiplier { record["cutFoilSimpleMultiplier"] = v as NSNumber }
        if let v = cutFoilMediumMultiplier { record["cutFoilMediumMultiplier"] = v as NSNumber }
        if let v = cutFoilComplexMultiplier { record["cutFoilComplexMultiplier"] = v as NSNumber }
        return record
    }

    init?(record: CKRecord) {
        guard
            let basePackagesJSON = record["tintBasePackagesJSON"] as? String,
            let extrasJSON = record["tintExtrasJSON"] as? String,
            let partsJSON = record["dechromePartsJSON"] as? String,
            let basePackagesData = basePackagesJSON.data(using: .utf8),
            let extrasData = extrasJSON.data(using: .utf8),
            let partsData = partsJSON.data(using: .utf8),
            let basePackages = try? JSONDecoder().decode([PriceListEntry].self, from: basePackagesData),
            let extras = try? JSONDecoder().decode([PriceListEntry].self, from: extrasData),
            let parts = try? JSONDecoder().decode([PriceListEntry].self, from: partsData)
        else { return nil }
        let modifiedAt = record["modifiedAt"] as? Date
        let materials: [PriceListEntry]? = (record["cutFoilMaterialsJSON"] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([PriceListEntry].self, from: $0) }
        self.init(
            tintBasePackages: basePackages,
            tintExtras: extras,
            dechromeParts: parts,
            cutFoilMaterials: materials,
            cutFoilRollWidthCm: (record["cutFoilRollWidthCm"] as? NSNumber)?.doubleValue,
            cutFoilMarginCm: (record["cutFoilMarginCm"] as? NSNumber)?.doubleValue,
            cutFoilStartupCost: (record["cutFoilStartupCost"] as? NSNumber)?.doubleValue,
            cutFoilLaborPricePerM2: (record["cutFoilLaborPricePerM2"] as? NSNumber)?.doubleValue,
            cutFoilMinimumPricePerPiece: (record["cutFoilMinimumPricePerPiece"] as? NSNumber)?.doubleValue,
            cutFoilSimpleMultiplier: (record["cutFoilSimpleMultiplier"] as? NSNumber)?.doubleValue,
            cutFoilMediumMultiplier: (record["cutFoilMediumMultiplier"] as? NSNumber)?.doubleValue,
            cutFoilComplexMultiplier: (record["cutFoilComplexMultiplier"] as? NSNumber)?.doubleValue,
            modifiedAt: modifiedAt
        )
    }
}
