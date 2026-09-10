import Foundation
import CloudKit

/// Eén verzonden aanvraag/offerte, gearchiveerd op het moment dat hij via
/// WhatsApp, e-mail of Moneybird de deur uit ging — zodat je bij een klant
/// (tabblad Klanten, "Geschiedenis") kunt terugzien wat er ooit
/// aangevraagd/geoffreerd is. Losstaand van `RequestStore` (dat is de
/// tijdelijke aanvraag die je op dit moment aan het opbouwen bent, en die
/// bewust niet gearchiveerd wordt — zie de toelichting daar): dit is een
/// onveranderlijke momentopname van het totaal en de kopieertekst op het
/// moment van versturen.
struct ArchivedQuote: Identifiable, Hashable {
    var id: UUID = UUID()
    var customerID: UUID
    /// Hoe deze aanvraag de deur uit ging, bijv. "WhatsApp", "E-mail",
    /// "Moneybird offerte" of "Moneybird factuur".
    var channel: String = ""
    /// De volledige kopieertekst zoals die op dat moment verstuurd is
    /// (dezelfde opbouw als de "Voorbeeld van de kopieertekst"-kaart).
    var summary: String = ""
    var total: Double = 0
    var sentAt: Date = Date()
    /// Wanneer deze regel voor het laatst is aangepast — gebruikt door de
    /// cloud-synchronisatie om te bepalen welke versie (lokaal of van een
    /// ander apparaat) de nieuwste is.
    var modifiedAt: Date = Date()

    private enum CodingKeys: String, CodingKey { case id, customerID, channel, summary, total, sentAt, modifiedAt }

    init(id: UUID = UUID(), customerID: UUID, channel: String = "", summary: String = "", total: Double = 0, sentAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.customerID = customerID
        self.channel = channel
        self.summary = summary
        self.total = total
        self.sentAt = sentAt
        self.modifiedAt = modifiedAt
    }
}

extension ArchivedQuote: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        customerID = try container.decodeIfPresent(UUID.self, forKey: .customerID) ?? UUID()
        channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(customerID, forKey: .customerID)
        try container.encode(channel, forKey: .channel)
        try container.encode(summary, forKey: .summary)
        try container.encode(total, forKey: .total)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

/// Archief van verzonden aanvragen/offertes, per klant. Volgt hetzelfde
/// patroon als `OrderListStore`/`ProjectStore`: los CloudKit-record per
/// item (op id), zodat toevoegen op één apparaat niet de wijzigingen van
/// een ander apparaat overschrijft.
@MainActor
final class QuoteArchiveStore: ObservableObject {
    @Published private(set) var items: [ArchivedQuote] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.QuoteArchive.Items.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedQuoteArchiveIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingQuoteArchiveDeletions"

    init() {
        load()
        Task { await syncWithCloud() }
    }

    /// Alle gearchiveerde aanvragen voor één klant, nieuwste eerst — voor de
    /// "Geschiedenis"-sectie bij Klanten.
    func quotes(for customerID: UUID) -> [ArchivedQuote] {
        items.filter { $0.customerID == customerID }.sorted { $0.sentAt > $1.sentAt }
    }

    @discardableResult
    func add(customerID: UUID, channel: String, summary: String, total: Double) -> ArchivedQuote {
        let quote = ArchivedQuote(customerID: customerID, channel: channel, summary: summary, total: total)
        items.append(quote)
        persistLocally()
        Task { await push(quote) }
        return quote
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        persistLocally()
        addPendingDeletion(id)
        Task { await flushPendingDeletions() }
    }

    // MARK: - Lokale opslag

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ArchivedQuote].self, from: data) else { return }
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

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: ArchivedQuote.recordType)
        let remoteItems = remoteRecords.compactMap(ArchivedQuote.init(record:))
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

    private func push(_ item: ArchivedQuote) async {
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

private extension ArchivedQuote {
    static let recordType = "ArchivedQuote"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["customerID"] = customerID.uuidString as NSString
        record["channel"] = channel as NSString
        record["summary"] = summary as NSString
        record["total"] = total as NSNumber
        record["sentAt"] = sentAt as NSDate
        record["modifiedAt"] = modifiedAt as NSDate
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let customerIDString = record["customerID"] as? String,
            let customerID = UUID(uuidString: customerIDString),
            let channel = record["channel"] as? String,
            let summary = record["summary"] as? String,
            let total = record["total"] as? Double,
            let sentAt = record["sentAt"] as? Date,
            let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        self.init(id: id, customerID: customerID, channel: channel, summary: summary, total: total, sentAt: sentAt, modifiedAt: modifiedAt)
    }
}
