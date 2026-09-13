import Foundation
import CloudKit

/// Eén regel in de "kladblok"-bestellijst: een vrije tekstregel (bijv. "5 meter
/// Oracal 970 zwart — Firma X"), die je zelf in de gewenste volgorde kunt
/// zetten (bijv. per leverancier bij elkaar) en die je in één keer als platte
/// tekst kunt kopiëren om in een e-mail te plakken.
struct OrderListItem: Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    /// Wanneer deze regel voor het laatst is aangepast — gebruikt door de
    /// cloud-synchronisatie om te bepalen welke versie (lokaal of van een
    /// ander apparaat) de nieuwste is.
    var modifiedAt: Date = Date()

    private enum CodingKeys: String, CodingKey { case id, text, modifiedAt }

    init(id: UUID = UUID(), text: String = "", modifiedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.modifiedAt = modifiedAt
    }
}

extension OrderListItem: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

/// Kladblok voor de bestelling die je op dit moment aan het samenstellen bent
/// — los van `SupplyStore` (dat is je naslaglijst met vaste artikelen).
/// Volgorde is hier bewust belangrijk (zodat je per leverancier kunt
/// sorteren), dus die blijft bij het synchroniseren staan zoals hij lokaal
/// is: nieuwe regels van een ander apparaat worden onderaan toegevoegd,
/// bestaande regels worden op hun eigen plek bijgewerkt.
@MainActor
final class OrderListStore: ObservableObject {
    @Published private(set) var items: [OrderListItem] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.OrderList.Items.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedOrderListItemIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingOrderListItemDeletions"

    /// Eén lopende, uitgestelde push-taak per regel — zodat direct typen in
    /// een regel (zie `update(id:text:)`) niet bij elk toetsaanslag een
    /// netwerkverzoek naar de cloud stuurt, maar pas kort nadat je stopt met
    /// typen. Lokaal (het scherm, en de opslag op dit apparaat) blijft wel
    /// meteen bij, zodat typen zelf niet vertraagd voelt.
    private var pendingPushTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        load()
        Task { await syncWithCloud() }
    }

    @discardableResult
    func add(text: String) -> OrderListItem? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let item = OrderListItem(text: cleaned)
        items.append(item)
        persistLocally()
        Task { await push(item) }
        return item
    }

    /// Werkt de tekst van een regel bij terwijl je typt — direct in het
    /// scherm bewerkbaar, zonder los invoerveld. Bewust geen trim/leeg-check
    /// hier (anders "springt" het tekstveld terug zodra je alles wegtypt);
    /// een lege regel kun je gewoon met het prullenbak-icoon verwijderen.
    func update(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        items[index].modifiedAt = Date()
        persistLocally()
        schedulePush(items[index])
    }

    private func schedulePush(_ item: OrderListItem) {
        pendingPushTasks[item.id]?.cancel()
        pendingPushTasks[item.id] = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await push(item)
            pendingPushTasks[item.id] = nil
        }
    }

    func delete(id: UUID) {
        pendingPushTasks[id]?.cancel()
        pendingPushTasks[id] = nil
        items.removeAll { $0.id == id }
        persistLocally()
        addPendingDeletion(id)
        Task { await flushPendingDeletions() }
    }

    /// Verplaatst een regel één plek omhoog (`direction: -1`) of omlaag
    /// (`direction: 1`) — voor het handmatig sorteren, bijv. per leverancier.
    func move(id: UUID, direction: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + direction
        guard items.indices.contains(newIndex) else { return }
        items.swapAt(index, newIndex)
        persistLocally()
    }

    /// Wist de hele kladblok-lijst, bijv. nadat de bestelling verstuurd is en
    /// je met een schone lijst opnieuw wilt beginnen.
    func clear() {
        let ids = items.map(\.id)
        for id in ids {
            pendingPushTasks[id]?.cancel()
            pendingPushTasks[id] = nil
        }
        items.removeAll()
        persistLocally()
        for id in ids { addPendingDeletion(id) }
        Task { await flushPendingDeletions() }
    }

    /// Alle regels als platte tekst, elk op een eigen regel — voor het
    /// kopiëren naar een e-mail.
    var copyText: String {
        items.map(\.text).joined(separator: "\n")
    }

    // MARK: - Lokale opslag

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([OrderListItem].self, from: data) else { return }
        items = decoded
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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

    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: OrderListItem.recordType)
        guard CloudSyncCenter.shared.lastDiagnostic == nil else {
            // Ophalen mislukt: niet vergelijken/verwijderen, lokale data blijft staan.
            return
        }
        let remoteItems = remoteRecords.compactMap(OrderListItem.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.id, $0) })

        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var idsToRemove: Set<UUID> = []
        var merged = items
        var changed = false

        for index in merged.indices {
            let local = merged[index]
            if let remote = remoteByID[local.id] {
                currentSyncedIDs.insert(local.id)
                if remote.modifiedAt > local.modifiedAt {
                    merged[index] = remote
                    changed = true
                } else if local.modifiedAt > remote.modifiedAt {
                    idsToPush.append(local.id)
                }
            } else if currentSyncedIDs.contains(local.id) {
                idsToRemove.insert(local.id) // elders verwijderd
            } else {
                idsToPush.append(local.id) // nog nooit gesynchroniseerd
            }
        }

        if !idsToRemove.isEmpty {
            merged.removeAll { idsToRemove.contains($0.id) }
            changed = true
        }

        let localIDs = Set(merged.map(\.id))
        for remote in remoteItems where !localIDs.contains(remote.id) {
            merged.append(remote)
            currentSyncedIDs.insert(remote.id)
            changed = true
        }

        syncedIDs = currentSyncedIDs
        if changed {
            items = merged
            persistLocally()
        }

        for id in idsToPush {
            if let item = merged.first(where: { $0.id == id }) {
                await push(item)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ item: OrderListItem) async {
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

private extension OrderListItem {
    static let recordType = "OrderListItem"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["text"] = text as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let text = record["text"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        self.init(id: id, text: text, modifiedAt: modifiedAt)
    }
}
