import Foundation
import CloudKit

/// Eén artikel op de bestellijst: naam, categorie en waar/hoe het besteld
/// wordt. Puur een naslaglijstje voor Robin zelf, niet gekoppeld aan klanten
/// of offertes. De categorie is vrije tekst (net als bij ProductStore) zodat
/// hij zelf nieuwe categorieën kan toevoegen naast Folie/Vloeistoffen/Doeken.
struct SupplyItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var category: String = "Folie"
    var supplier: String = ""
    var articleNumber: String = ""
    var orderLink: String = ""
    var note: String = ""
    /// Wanneer dit artikel voor het laatst is aangepast — gebruikt door de
    /// cloud-synchronisatie om te bepalen welke versie (lokaal of van een
    /// ander apparaat) de nieuwste is. Ontbreekt dit veld in een ouder,
    /// lokaal opgeslagen bestand (van vóór de cloud-synchronisatie), dan
    /// wordt het moment van inlezen gebruikt — zonder deze fallback zou het
    /// hele bestand (inclusief alle al bestaande artikelen!) niet meer
    /// inlezen, met dataverlies tot gevolg.
    var modifiedAt: Date = Date()

    var displayText: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nieuw artikel" : name
    }

    /// De bestel-link als geldige URL, met "https://" ervoor als de
    /// gebruiker die niet zelf heeft getypt.
    var orderURL: URL? {
        let trimmed = orderLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, supplier, articleNumber, orderLink, note, modifiedAt
    }

    init(id: UUID = UUID(), name: String = "", category: String = "Folie", supplier: String = "", articleNumber: String = "", orderLink: String = "", note: String = "", modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.category = category
        self.supplier = supplier
        self.articleNumber = articleNumber
        self.orderLink = orderLink
        self.note = note
        self.modifiedAt = modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Folie"
        supplier = try container.decodeIfPresent(String.self, forKey: .supplier) ?? ""
        articleNumber = try container.decodeIfPresent(String.self, forKey: .articleNumber) ?? ""
        orderLink = try container.decodeIfPresent(String.self, forKey: .orderLink) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(supplier, forKey: .supplier)
        try container.encode(articleNumber, forKey: .articleNumber)
        try container.encode(orderLink, forKey: .orderLink)
        try container.encode(note, forKey: .note)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

private struct SupplyData: Codable {
    var items: [SupplyItem] = []
}

/// Bestellijst, gedeeld tussen de Mac- en de mobiele app en gesynchroniseerd
/// via de cloud (zie CloudSync.swift) — net als Klanten, Producten en de
/// andere stores.
@MainActor
final class SupplyStore: ObservableObject {
    @Published private(set) var items: [SupplyItem] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let fileURL: URL

    private let syncedIDsKey = "TintKing.Sync.SyncedSupplyItemIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingSupplyItemDeletions"

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("TintKingCalculator", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("supplies.json")
        load()
        Task { await syncWithCloud() }
    }

    var sortedItems: [SupplyItem] {
        items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Alle gebruikte categorieën, gesorteerd, zonder duplicaten — voor de
    /// categoriekiezer bij het toevoegen/bewerken van een artikel.
    var categories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let category = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty, !seen.contains(category) else { continue }
            seen.insert(category)
            result.append(category)
        }
        return result.sorted()
    }

    func add(_ item: SupplyItem) {
        var newItem = item
        newItem.modifiedAt = Date()
        items.append(newItem)
        save()
        Task { await push(newItem) }
    }

    func update(_ item: SupplyItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.modifiedAt = Date()
        items[idx] = updated
        save()
        Task { await push(updated) }
    }

    func delete(_ item: SupplyItem) {
        items.removeAll { $0.id == item.id }
        save()
        addPendingDeletion(item.id)
        Task { await flushPendingDeletions() }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(SupplyData.self, from: data) else { return }
        items = decoded.items
    }

    private func save() {
        let data = SupplyData(items: items)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    // MARK: - Cloud-synchronisatie

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

    /// Haalt de laatste stand uit de cloud op, voegt artikelen van andere
    /// apparaten toe, werkt gewijzigde artikelen bij, en verwijdert artikelen
    /// die elders zijn verwijderd.
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: SupplyItem.recordType)
        guard CloudSyncCenter.shared.lastDiagnostic == nil else {
            // Ophalen mislukt: niet vergelijken/verwijderen, lokale data blijft staan.
            return
        }
        let remoteItems = remoteRecords.compactMap(SupplyItem.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        for remote in remoteItems {
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
            items = Array(localByID.values)
            save()
        }

        for id in idsToPush {
            if let item = localByID[id] {
                await push(item)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ item: SupplyItem) async {
        let record = item.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(item.id)
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

// MARK: - Cloud-mapping

private extension SupplyItem {
    static let recordType = "SupplyItem"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["category"] = category as NSString
        record["supplier"] = supplier as NSString
        record["articleNumber"] = articleNumber as NSString
        record["orderLink"] = orderLink as NSString
        record["note"] = note as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        let category = (record["category"] as? String) ?? "Folie"
        let supplier = (record["supplier"] as? String) ?? ""
        let articleNumber = (record["articleNumber"] as? String) ?? ""
        let orderLink = (record["orderLink"] as? String) ?? ""
        let note = (record["note"] as? String) ?? ""
        self.init(id: id, name: name, category: category, supplier: supplier, articleNumber: articleNumber, orderLink: orderLink, note: note, modifiedAt: modifiedAt)
    }
}
