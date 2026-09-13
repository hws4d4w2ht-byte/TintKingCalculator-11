import Foundation
import CloudKit

/// Een zelf opgeslagen ontchroom-preset. Gedeeld tussen de Mac- en de mobiele app,
/// en gesynchroniseerd via iCloud zodat een preset die je op de ene plek opslaat ook
/// op je andere apparaten verschijnt.
struct DechromePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prices: [String: Double]
    var modifiedAt: Date = Date()
}

@MainActor
final class DechromePresetStore: ObservableObject {
    @Published private(set) var presets: [DechromePreset] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.CustomDechromePresets.v2"
    private let syncedIDsKey = "TintKing.Sync.SyncedDechromePresetIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingDechromePresetDeletions"

    init() {
        load()
        Task { await syncWithCloud() }
    }

    @discardableResult
    func add(name: String, prices: [String: Double]) -> String {
        let finalName = uniqueName(name)
        let preset = DechromePreset(name: finalName, prices: prices, modifiedAt: Date())
        presets.append(preset)
        persistLocally()
        Task { await push(preset) }
        return finalName
    }

    func update(name: String, prices: [String: Double]) {
        guard let index = presets.firstIndex(where: { $0.name == name }) else { return }
        presets[index].prices = prices
        presets[index].modifiedAt = Date()
        let updated = presets[index]
        persistLocally()
        Task { await push(updated) }
    }

    func delete(name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        presets.removeAll { $0.name == name }
        persistLocally()
        addPendingDeletion(preset.id)
        Task { await flushPendingDeletions() }
    }

    private func uniqueName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Nieuwe preset" : trimmed
        let used = Set(presets.map(\.name) + Array(dechromePresets.keys))
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DechromePreset].self, from: data) else { return }
        presets = decoded
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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

    /// Haalt de laatste stand uit iCloud op, voegt presets van andere apparaten toe,
    /// werkt gewijzigde presets bij, en verwijdert presets die elders zijn verwijderd.
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: DechromePreset.recordType)
        guard CloudSyncCenter.shared.lastDiagnostic == nil else {
            // Ophalen mislukt: niet vergelijken/verwijderen, lokale data blijft staan.
            return
        }
        let remotePresets = remoteRecords.compactMap(DechromePreset.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remotePresets.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        for remote in remotePresets {
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
            presets = Array(localByID.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            persistLocally()
        }

        for id in idsToPush {
            if let preset = localByID[id] {
                await push(preset)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ preset: DechromePreset) async {
        let record = preset.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(preset.id)
            syncedIDs = synced
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

private extension DechromePreset {
    static let recordType = "DechromePreset"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        if let data = try? JSONEncoder().encode(prices), let json = String(data: data, encoding: .utf8) {
            record["pricesJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date,
            let pricesJSON = record["pricesJSON"] as? String,
            let pricesData = pricesJSON.data(using: .utf8),
            let prices = try? JSONDecoder().decode([String: Double].self, from: pricesData)
        else { return nil }
        self.init(id: id, name: name, prices: prices, modifiedAt: modifiedAt)
    }
}
