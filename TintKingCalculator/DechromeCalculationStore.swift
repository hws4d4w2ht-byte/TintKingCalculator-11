import Foundation
import CloudKit

/// Eén tijdelijk opgeslagen Ontchromen-calculatie: alle gekozen onderdelen met
/// hun prijzen op het moment van opslaan, plus korting — zodat je een lopende
/// offerte kunt onderbreken en later, via de sidebar in Ontchromen, weer
/// verder kunt werken. Vervangt het losse "preset"-systeem (zie
/// DechromePresetStore.swift), dat alleen prijzen per automodel onthield.
struct SavedDechromeCalculation: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var selectedParts: Set<String> = []
    var selectedPartOrder: [String] = []
    /// Prijs van élk gekozen onderdeel op het moment van opslaan — zo blijft
    /// deze calculatie zelfstandig leesbaar, ook als de prijslijst of een
    /// standaard preset later verandert.
    var manualPrices: [String: Double] = [:]
    var customParts: [String: Double] = [:]
    var discountMode: DiscountMode = .none
    var discountPercentage: Double = 0
    var discountFixedAmount: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, selectedParts, selectedPartOrder
        case manualPrices, customParts, discountMode, discountPercentage, discountFixedAmount
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        selectedParts: Set<String> = [],
        selectedPartOrder: [String] = [],
        manualPrices: [String: Double] = [:],
        customParts: [String: Double] = [:],
        discountMode: DiscountMode = .none,
        discountPercentage: Double = 0,
        discountFixedAmount: Double = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.selectedParts = selectedParts
        self.selectedPartOrder = selectedPartOrder
        self.manualPrices = manualPrices
        self.customParts = customParts
        self.discountMode = discountMode
        self.discountPercentage = discountPercentage
        self.discountFixedAmount = discountFixedAmount
    }

    var displayName: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Naamloze calculatie" : cleaned
    }

    /// Totaalprijs voor de sidebar-rij, zonder dat daarvoor de actuele
    /// prijslijst/presets nodig zijn — bij het opslaan is de op dat moment
    /// geldende prijs van élk gekozen onderdeel al vastgelegd in `manualPrices`.
    var total: Double {
        selectedParts.reduce(0) { $0 + (manualPrices[$1] ?? customParts[$1] ?? 0) }
    }
}

extension SavedDechromeCalculation: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        selectedParts = try container.decodeIfPresent(Set<String>.self, forKey: .selectedParts) ?? []
        selectedPartOrder = try container.decodeIfPresent([String].self, forKey: .selectedPartOrder) ?? []
        manualPrices = try container.decodeIfPresent([String: Double].self, forKey: .manualPrices) ?? [:]
        customParts = try container.decodeIfPresent([String: Double].self, forKey: .customParts) ?? [:]
        discountMode = try container.decodeIfPresent(DiscountMode.self, forKey: .discountMode) ?? .none
        discountPercentage = try container.decodeIfPresent(Double.self, forKey: .discountPercentage) ?? 0
        discountFixedAmount = try container.decodeIfPresent(Double.self, forKey: .discountFixedAmount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(selectedParts, forKey: .selectedParts)
        try container.encode(selectedPartOrder, forKey: .selectedPartOrder)
        try container.encode(manualPrices, forKey: .manualPrices)
        try container.encode(customParts, forKey: .customParts)
        try container.encode(discountMode, forKey: .discountMode)
        try container.encode(discountPercentage, forKey: .discountPercentage)
        try container.encode(discountFixedAmount, forKey: .discountFixedAmount)
    }
}

@MainActor
final class DechromeCalculationStore: ObservableObject {
    @Published private(set) var calculations: [SavedDechromeCalculation] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.DechromeCalculations.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedDechromeCalculationIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingDechromeCalculationDeletions"

    /// Sleutel van het oude, losse preset-systeem (zie DechromePresetStore.swift)
    /// — alleen gebruikt voor een eenmalige, automatische overzetting hieronder.
    /// Deze sleutel zelf wordt nooit aangepast of gewist, als extra vangnet.
    private let legacyPresetStorageKey = "TintKing.CustomDechromePresets.v2"

    init() {
        load()
        migrateLegacyPresetsIfNeeded()
        Task { await syncWithCloud() }
    }

    func clearError() {
        lastError = nil
    }

    func calculation(id: UUID?) -> SavedDechromeCalculation? {
        guard let id else { return nil }
        return calculations.first(where: { $0.id == id })
    }

    @discardableResult
    func save(
        name: String,
        selectedParts: Set<String>,
        selectedPartOrder: [String],
        manualPrices: [String: Double],
        customParts: [String: Double],
        discountMode: DiscountMode,
        discountPercentage: Double,
        discountFixedAmount: Double,
        id: UUID?
    ) -> UUID {
        let now = Date()
        let resultID: UUID

        if let id, let index = calculations.firstIndex(where: { $0.id == id }) {
            calculations[index].name = name
            calculations[index].selectedParts = selectedParts
            calculations[index].selectedPartOrder = selectedPartOrder
            calculations[index].manualPrices = manualPrices
            calculations[index].customParts = customParts
            calculations[index].discountMode = discountMode
            calculations[index].discountPercentage = discountPercentage
            calculations[index].discountFixedAmount = discountFixedAmount
            calculations[index].modifiedAt = now
            resultID = id
        } else {
            let new = SavedDechromeCalculation(
                name: name,
                createdAt: now,
                modifiedAt: now,
                selectedParts: selectedParts,
                selectedPartOrder: selectedPartOrder,
                manualPrices: manualPrices,
                customParts: customParts,
                discountMode: discountMode,
                discountPercentage: discountPercentage,
                discountFixedAmount: discountFixedAmount
            )
            calculations.append(new)
            sortCalculations()
            resultID = new.id
        }

        persistLocally()
        if let saved = calculation(id: resultID) {
            Task { await push(saved) }
        }
        return resultID
    }

    @discardableResult
    func duplicate(id: UUID) -> UUID? {
        guard let source = calculations.first(where: { $0.id == id }) else { return nil }
        return save(
            name: "\(source.displayName) – kopie",
            selectedParts: source.selectedParts,
            selectedPartOrder: source.selectedPartOrder,
            manualPrices: source.manualPrices,
            customParts: source.customParts,
            discountMode: source.discountMode,
            discountPercentage: source.discountPercentage,
            discountFixedAmount: source.discountFixedAmount,
            id: nil
        )
    }

    func delete(id: UUID) {
        calculations.removeAll(where: { $0.id == id })
        persistLocally()
        addPendingDeletion(id)
        Task { await flushPendingDeletions() }
    }

    private func sortCalculations() {
        calculations.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SavedDechromeCalculation].self, from: data) else { return }
        calculations = decoded
        sortCalculations()
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(calculations) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Zet bestaande, lokaal opgeslagen presets uit het oude systeem
    /// (DechromePresetStore) eenmalig om naar deze nieuwe opslag, zodat bijv.
    /// een eerder opgeslagen "Audi E-Tron"-preset niet kwijtraakt. Draait
    /// alleen als deze nieuwe opslag nog helemaal leeg is; de oude sleutel
    /// zelf blijft ongemoeid staan (niets wordt verwijderd).
    private func migrateLegacyPresetsIfNeeded() {
        guard calculations.isEmpty,
              let data = UserDefaults.standard.data(forKey: legacyPresetStorageKey),
              let legacyPresets = try? JSONDecoder().decode([DechromePreset].self, from: data),
              !legacyPresets.isEmpty
        else { return }

        calculations = legacyPresets.map { preset in
            SavedDechromeCalculation(
                id: preset.id,
                name: preset.name,
                createdAt: preset.modifiedAt,
                modifiedAt: preset.modifiedAt,
                selectedParts: Set(preset.prices.keys),
                selectedPartOrder: preset.prices.keys.sorted(),
                manualPrices: preset.prices
            )
        }
        sortCalculations()
        persistLocally()
    }

    // MARK: - iCloud-synchronisatie

    private var syncedIDs: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: syncedIDsKey) as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: syncedIDsKey) }
    }

    private var pendingDeletions: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: pendingDeletionsKey) as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: pendingDeletionsKey) }
    }

    private func addPendingDeletion(_ id: UUID) {
        var current = pendingDeletions
        current.insert(id)
        pendingDeletions = current
        var synced = syncedIDs
        synced.remove(id)
        syncedIDs = synced
    }

    /// Haalt de laatste stand uit iCloud op. Kan gerust vaak worden aangeroepen
    /// (bijv. bij het openen van dit scherm, of via een 'Synchroniseer nu'-knop).
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else {
            lastError = CloudSyncCenter.shared.lastDiagnostic ?? "iCloud is nu niet beschikbaar."
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: SavedDechromeCalculation.recordType)
        if remoteRecords.isEmpty, let diagnostic = CloudSyncCenter.shared.lastDiagnostic {
            lastError = diagnostic
        }
        let remoteCalculations = remoteRecords.compactMap(SavedDechromeCalculation.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCalculations.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: calculations.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        for remote in remoteCalculations {
            if let local = localByID[remote.id] {
                if remote.modifiedAt > local.modifiedAt {
                    localByID[remote.id] = remote
                    changed = true
                }
            } else {
                localByID[remote.id] = remote
                changed = true
            }
            currentSyncedIDs.insert(remote.id)
        }

        for local in localByID.values {
            if let remote = remoteByID[local.id] {
                if local.modifiedAt > remote.modifiedAt {
                    idsToPush.append(local.id)
                }
            } else if currentSyncedIDs.contains(local.id) {
                localByID.removeValue(forKey: local.id)
                changed = true
            } else {
                idsToPush.append(local.id)
            }
        }

        syncedIDs = currentSyncedIDs

        if changed {
            calculations = Array(localByID.values)
            sortCalculations()
            persistLocally()
        }

        for id in idsToPush {
            if let calc = localByID[id] {
                await push(calc)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ calc: SavedDechromeCalculation) async {
        let record = calc.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(calc.id)
            syncedIDs = synced
        } else {
            lastError = CloudSyncCenter.shared.lastDiagnostic ?? "Opslaan naar iCloud is niet gelukt."
        }
    }

    private func flushPendingDeletions() async {
        let ids = pendingDeletions
        guard !ids.isEmpty else { return }
        let recordIDs = ids.map { CloudSyncCenter.shared.recordID(name: $0.uuidString) }
        if await CloudSyncCenter.shared.delete(recordIDs: recordIDs) {
            pendingDeletions = []
        }
    }
}

// MARK: - CloudKit-mapping

private extension SavedDechromeCalculation {
    static let recordType = "DechromeCalculation"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["createdAt"] = createdAt as NSDate
        record["modifiedAt"] = modifiedAt as NSDate
        if let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) {
            record["dataJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let dataJSON = record["dataJSON"] as? String,
            let data = dataJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SavedDechromeCalculation.self, from: data)
        else { return nil }
        self = decoded
    }
}
