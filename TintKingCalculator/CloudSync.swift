import Foundation
import CloudKit

/// Centrale configuratie voor iCloud-synchronisatie (CloudKit). Wordt gebruikt door
/// ProjectStore, PriceListStore en DechromePresetStore, op zowel de Mac- als de
/// mobiele app. Beide targets moeten de iCloud-capability met dezelfde
/// container-identifier hebben ingeschakeld (zie de .entitlements-bestanden en
/// Signing & Capabilities in Xcode).
enum CloudSyncConfig {
    static let containerIdentifier = "iCloud.nl.tintking.calculator"
    static let zoneName = "TintKingZone"

    /// Tijdelijk uitgeschakeld zolang de iCloud-capability niet actief is (Apple
    /// Developer Program-verificatie nog niet afgerond). Zonder dit crasht de app
    /// zodra hij een CKContainer probeert aan te maken zonder de bijbehorende
    /// entitlement. Zet dit terug op `true` zodra de capability weer aan staat in
    /// Signing & Capabilities (en de .entitlements-bestanden weer zijn ingevuld).
    static let isEnabled = false
}

/// Lichte, generieke wrapper rond CloudKit. Alle drie de stores gebruiken deze om
/// records te lezen en te schrijven in dezelfde eigen (private) zone. Faalt een
/// aanroep (geen internet, niet ingelogd, capability nog niet ingesteld), dan geeft
/// deze klasse dat netjes terug zonder te crashen — de app blijft gewoon lokaal werken.
final class CloudSyncCenter {
    static let shared = CloudSyncCenter()

    private let container: CKContainer?
    private let database: CKDatabase?
    let zoneID: CKRecordZone.ID
    private var zoneReady = false

    private init() {
        if CloudSyncConfig.isEnabled {
            let c = CKContainer(identifier: CloudSyncConfig.containerIdentifier)
            container = c
            database = c.privateCloudDatabase
        } else {
            container = nil
            database = nil
        }
        zoneID = CKRecordZone.ID(zoneName: CloudSyncConfig.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Of er op dit moment een bruikbaar iCloud-account is. Zo niet, dan slaan alle
    /// sync-aanroepen zichzelf stilletjes over.
    var isAccountAvailable: Bool {
        get async {
            guard CloudSyncConfig.isEnabled, let container else { return false }
            return (try? await container.accountStatus()) == .some(.available)
        }
    }

    /// Maakt de eigen zone aan als die nog niet bestaat. Mag zo vaak worden aangeroepen
    /// als je wilt — is goedkoop en veilig als de zone al bestaat.
    func ensureZoneExists() async {
        guard CloudSyncConfig.isEnabled, let database else { return }
        guard !zoneReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            zoneReady = true
        } catch {
            // Geen verbinding, niet ingelogd, of capability nog niet actief:
            // gewoon opnieuw proberen bij de volgende synchronisatie.
        }
    }

    /// Haalt alle records van een bepaald recordtype op uit de eigen zone.
    func fetchAllRecords(recordType: String) async -> [CKRecord] {
        guard CloudSyncConfig.isEnabled, let database else { return [] }
        await ensureZoneExists()
        var results: [CKRecord] = []
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))

        do {
            let first = try await database.records(matching: query, inZoneWith: zoneID)
            results.append(contentsOf: first.matchResults.compactMap { try? $0.1.get() })
            var cursor = first.queryCursor

            while let currentCursor = cursor {
                let next = try await database.records(continuingMatchFrom: currentCursor)
                results.append(contentsOf: next.matchResults.compactMap { try? $0.1.get() })
                cursor = next.queryCursor
            }
        } catch {
            // Nog geen records, of (tijdelijk) niet bereikbaar: lokale data blijft leidend.
        }
        return results
    }

    /// Slaat records op in de eigen zone (maakt aan of overschrijft).
    @discardableResult
    func save(records: [CKRecord]) async -> Bool {
        guard CloudSyncConfig.isEnabled, let database else { return false }
        guard !records.isEmpty else { return true }
        await ensureZoneExists()
        do {
            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
            return true
        } catch {
            return false
        }
    }

    /// Verwijdert records uit de eigen zone. Een record dat er al niet meer was telt
    /// als geslaagd — dat is precies wat we willen bij het opruimen van verwijderingen.
    @discardableResult
    func delete(recordIDs: [CKRecord.ID]) async -> Bool {
        guard CloudSyncConfig.isEnabled, let database else { return false }
        guard !recordIDs.isEmpty else { return true }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: recordIDs, savePolicy: .changedKeys)
            return true
        } catch let error as CKError where error.code == .partialFailure {
            guard let partial = error.partialErrorsByItemID else { return false }
            let realFailures = partial.values.contains { ($0 as? CKError)?.code != .unknownItem }
            return !realFailures
        } catch {
            return false
        }
    }

    func recordID(name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }
}
