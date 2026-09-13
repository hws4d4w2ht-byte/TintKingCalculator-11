import Foundation
import Combine
import CloudKit

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [SavedProject] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let fileURL: URL
    private let syncedIDsKey = "TintKing.Sync.SyncedProjectIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingProjectDeletions"

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("TintKingCalculator", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("projects.json")
        load()
        Task { await syncWithCloud() }
    }

    func clearError() {
        lastError = nil
    }

    func project(id: UUID?) -> SavedProject? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
    }

    @discardableResult
    func save(input: CalculationInput, settings: CalculatorSettings, projectID: UUID?) -> UUID {
        let now = Date()
        let resultID: UUID

        if let projectID, let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].input = input
            projects[index].settings = settings
            projects[index].modifiedAt = now
            resultID = projectID
        } else {
            let new = SavedProject(
                id: UUID(),
                createdAt: now,
                modifiedAt: now,
                input: input,
                settings: settings
            )
            projects.append(new)
            sortProjects()
            resultID = new.id
        }

        persistLocally()
        if let saved = project(id: resultID) {
            Task { await pushProject(saved) }
        }
        return resultID
    }

    @discardableResult
    func duplicate(projectID: UUID) -> UUID? {
        guard let source = projects.first(where: { $0.id == projectID }) else { return nil }
        var copiedInput = source.input
        let base = source.displayName
        copiedInput.projectName = "\(base) – kopie"
        return save(input: copiedInput, settings: source.settings, projectID: nil)
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            projects = try JSONDecoder().decode([SavedProject].self, from: data)
            sortProjects()
            lastError = nil
        } catch {
            lastError = "Opgeslagen projecten konden niet worden geladen: \(error.localizedDescription)"
        }
    }

    private func persistLocally() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: [.atomic])
            sortProjects()
            lastError = nil
        } catch {
            lastError = "Project kon niet worden opgeslagen: \(error.localizedDescription)"
        }
    }

    // MARK: - iCloud-synchronisatie
    //
    // Elk project is een los CloudKit-record (op id), zodat toevoegen/bewerken/
    // verwijderen op één apparaat niet de wijzigingen van een ander apparaat
    // overschrijft. Bij conflicten wint de nieuwste `modifiedAt`. Verwijderingen
    // worden bijgehouden in `pendingDeletions` totdat ze bevestigd in iCloud zijn
    // verwerkt, zodat een verwijdering die offline gebeurde later alsnog doorkomt.

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
    /// (bijv. bij het openen van een scherm, of via een 'Synchroniseer nu'-knop).
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: SavedProject.recordType)
        if let diagnostic = CloudSyncCenter.shared.lastDiagnostic {
            // Ophalen mislukt: niet vergelijken/verwijderen, lokale data blijft staan.
            lastError = diagnostic
            return
        }
        let remoteProjects = remoteRecords.compactMap(SavedProject.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteProjects.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        // Nieuwe of gewijzigde projecten van andere apparaten overnemen.
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

        // Lokale projecten die nog nooit gesynchroniseerd zijn, of die lokaal nieuwer
        // zijn dan de cloudversie, alsnog naar iCloud pushen. Een project dat wel al
        // eens gesynchroniseerd was maar nu niet meer in de cloud voorkomt, is elders
        // verwijderd.
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
                await pushProject(project)
            }
        }

        lastSyncedAt = Date()
    }

    private func pushProject(_ project: SavedProject) async {
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

private extension SavedProject {
    static let recordType = "Project"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["createdAt"] = createdAt as NSDate
        record["modifiedAt"] = modifiedAt as NSDate
        if let data = try? JSONEncoder().encode(input), let json = String(data: data, encoding: .utf8) {
            record["inputJSON"] = json as NSString
        }
        if let data = try? JSONEncoder().encode(settings), let json = String(data: data, encoding: .utf8) {
            record["settingsJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let createdAt = record["createdAt"] as? Date,
            let modifiedAt = record["modifiedAt"] as? Date,
            let inputJSON = record["inputJSON"] as? String,
            let settingsJSON = record["settingsJSON"] as? String,
            let inputData = inputJSON.data(using: .utf8),
            let settingsData = settingsJSON.data(using: .utf8),
            let input = try? JSONDecoder().decode(CalculationInput.self, from: inputData),
            let settings = try? JSONDecoder().decode(CalculatorSettings.self, from: settingsData)
        else { return nil }
        self.init(id: id, createdAt: createdAt, modifiedAt: modifiedAt, input: input, settings: settings)
    }
}
