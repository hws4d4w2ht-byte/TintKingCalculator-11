import Foundation
import CloudKit

@MainActor
final class KozijnProjectStore: ObservableObject {
    @Published private(set) var projects: [KozijnProject] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.KozijnProjects.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedKozijnProjectIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingKozijnProjectDeletions"

    init() {
        load()
        Task { await syncWithCloud() }
    }

    func project(id: UUID?) -> KozijnProject? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
    }

    @discardableResult
    func save(name: String, kozijnen: [KozijnItem], linkedCustomerID: UUID?, projectID: UUID?) -> UUID {
        let now = Date()
        let resultID: UUID

        if let projectID, let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].name = name
            projects[index].kozijnen = kozijnen
            projects[index].linkedCustomerID = linkedCustomerID
            projects[index].modifiedAt = now
            resultID = projectID
        } else {
            let new = KozijnProject(
                id: UUID(),
                name: name,
                kozijnen: kozijnen,
                linkedCustomerID: linkedCustomerID,
                modifiedAt: now
            )
            projects.append(new)
            resultID = new.id
        }

        sortProjects()
        persistLocally()
        if let saved = project(id: resultID) {
            Task { await push(saved) }
        }
        return resultID
    }

    @discardableResult
    func duplicate(projectID: UUID) -> UUID? {
        guard let source = projects.first(where: { $0.id == projectID }) else { return nil }
        return save(
            name: "\(source.displayName) – kopie",
            kozijnen: source.kozijnen,
            linkedCustomerID: source.linkedCustomerID,
            projectID: nil
        )
    }

    func delete(projectID: UUID) {
        projects.removeAll(where: { $0.id == projectID })
        persistLocally()
        addPendingDeletion(projectID)
        Task { await flushPendingDeletions() }
    }

    private func sortProjects() {
        projects.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([KozijnProject].self, from: data) else { return }
        projects = decoded
        sortProjects()
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - iCloud-synchronisatie
    //
    // Zelfde opzet als ProjectStore en DechromePresetStore: elk project is een los
    // CloudKit-record (op id), zodat opslaan/verwijderen op één apparaat niet de
    // wijzigingen van een ander apparaat overschrijft. Zolang CloudSyncConfig.isEnabled
    // nog op false staat, doen deze aanroepen niets — de projecten blijven dan gewoon
    // lokaal (UserDefaults) bewaard.

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

    /// Haalt de laatste stand uit iCloud op, voegt projecten van andere apparaten toe,
    /// werkt gewijzigde projecten bij, en verwijdert projecten die elders zijn verwijderd.
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: KozijnProject.recordType)
        let remoteProjects = remoteRecords.compactMap(KozijnProject.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteProjects.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        for remote in remoteProjects {
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
            projects = Array(localByID.values)
            sortProjects()
            persistLocally()
        }

        for id in idsToPush {
            if let project = localByID[id] {
                await push(project)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ project: KozijnProject) async {
        let record = project.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(project.id)
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

private extension KozijnProject {
    static let recordType = "KozijnProject"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        if let linkedCustomerID {
            record["linkedCustomerID"] = linkedCustomerID.uuidString as NSString
        }
        if let data = try? JSONEncoder().encode(kozijnen), let json = String(data: data, encoding: .utf8) {
            record["kozijnenJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date,
            let kozijnenJSON = record["kozijnenJSON"] as? String,
            let kozijnenData = kozijnenJSON.data(using: .utf8),
            let kozijnen = try? JSONDecoder().decode([KozijnItem].self, from: kozijnenData)
        else { return nil }
        let linkedCustomerID = (record["linkedCustomerID"] as? String).flatMap(UUID.init)
        self.init(id: id, name: name, kozijnen: kozijnen, linkedCustomerID: linkedCustomerID, modifiedAt: modifiedAt)
    }
}
