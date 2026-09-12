import Foundation
import CloudKit

/// Centrale configuratie voor cloud-synchronisatie. Wordt gebruikt door
/// ProjectStore, CustomerStore, PriceListStore, DechromePresetStore en de
/// andere stores, op zowel de Mac- als de mobiele app.
///
/// Draait sinds september 2026 weer op echte CloudKit/iCloud, nu er een
/// actief Apple Developer Program-lidmaatschap is (voorheen tijdelijk op
/// Supabase, zie `SupabaseFormsSync` hieronder — dat blijft bestaan, maar
/// wordt nu alleen nog gebruikt voor het (nog te bouwen) ophalen van
/// website-formulieren, niet meer voor deze kern-synchronisatie).
///
/// Gebruikt de eigen iCloud-container van de app (ingesteld via Xcode:
/// Signing & Capabilities → iCloud → CloudKit, op zowel de Mac- als de
/// mobiele target) en een eigen zone ("TintKingZone") in de *private*
/// database van de ingelogde iCloud-gebruiker. Dat betekent: de data is
/// alleen zichtbaar voor jouw eigen, met hetzelfde Apple ID ingelogde
/// apparaten — niet publiek en niet gedeeld met andere gebruikers.
///
/// Publieke interface is bewust identiek gehouden aan de vorige
/// (Supabase-)versie, zodat ProjectStore.swift, CustomerStore.swift,
/// PriceListStore.swift enzovoort geen letter aangepast hoefden te worden
/// voor deze omzetting.
final class CloudSyncCenter {
    static let shared = CloudSyncCenter()

    private let container = CKContainer.default()
    private lazy var database = container.privateCloudDatabase

    /// Puur nog een "koffertje"-waarde: dezelfde zone-ID die elke store
    /// gebruikt om zijn CKRecords te bouwen. Hier heeft die wél echt
    /// betekenis (het is de zone waar we ook echt in lezen/schrijven).
    let zoneID = CKRecordZone.ID(zoneName: "TintKingZone", ownerName: CKCurrentUserDefaultName)

    /// CloudKit vereist dat een custom zone bestaat vóór je er records in
    /// kunt opslaan of uit kunt lezen. Dit zorgt dat we dat maar één keer
    /// per appstart hoeven te proberen in plaats van voor elke aanroep.
    private var didEnsureZone = false

    private init() {}

    /// Of iCloud op dit moment bruikbaar is (ingelogd op dit apparaat, geen
    /// beperkingen zoals Schermtijd/ouderlijk toezicht, etc.).
    var isAccountAvailable: Bool {
        get async {
            (try? await container.accountStatus()) == .available
        }
    }

    /// Haalt alle records van een bepaald recordtype op uit de eigen zone.
    func fetchAllRecords(recordType: String) async -> [CKRecord] {
        guard await isAccountAvailable else { return [] }
        guard await ensureZoneExists() else { return [] }

        var records: [CKRecord] = []

        do {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var (matchResults, cursor) = try await database.records(matching: query, inZoneWith: zoneID)
            records.append(contentsOf: matchResults.compactMap { try? $0.1.get() })

            // CloudKit geeft resultaten in pagina's terug; blijf doorhalen
            // tot er geen volgende pagina meer is.
            while let currentCursor = cursor {
                let more = try await database.records(continuingMatchFrom: currentCursor)
                records.append(contentsOf: more.matchResults.compactMap { try? $0.1.get() })
                cursor = more.queryCursor
            }
        } catch {
            // Geen verbinding, of iCloud (tijdelijk) niet bereikbaar: lokale
            // data blijft leidend, precies zoals voorheen bij Supabase.
            return []
        }

        return records
    }

    /// Slaat records op (maakt aan of overschrijft).
    @discardableResult
    func save(records: [CKRecord]) async -> Bool {
        guard await isAccountAvailable else { return false }
        guard !records.isEmpty else { return true }
        guard await ensureZoneExists() else { return false }

        do {
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
            for (_, saveResult) in result.saveResults {
                if case .failure = saveResult {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Verwijdert records op basis van hun record-ID.
    @discardableResult
    func delete(recordIDs: [CKRecord.ID]) async -> Bool {
        guard await isAccountAvailable else { return false }
        guard !recordIDs.isEmpty else { return true }
        guard await ensureZoneExists() else { return false }

        do {
            let result = try await database.modifyRecords(saving: [], deleting: recordIDs)
            for (_, deleteResult) in result.deleteResults {
                if case .failure = deleteResult {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    func recordID(name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: - Zone

    private func ensureZoneExists() async -> Bool {
        if didEnsureZone { return true }
        do {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            didEnsureZone = true
            return true
        } catch {
            return false
        }
    }
}

/// Configuratie voor het (nog te bouwen) ophalen van website-formulieren via
/// n8n. Dit is de klasse die tot september 2026 de kern-synchronisatie deed
/// (zie `CloudSyncCenter` hierboven, die het nu overneemt met echte
/// CloudKit) — die rol is uitgespeeld, maar de Supabase-verbinding zelf
/// blijft klaarstaan, omdat n8n straks binnenkomende formulieren hierin kan
/// wegzetten totdat de app ze ophaalt.
///
/// Nog niet gekoppeld aan enige store — wordt pas gebruikt zodra de
/// formulieren-inbox feature gebouwd wordt.
enum SupabaseSyncConfig {
    /// Project Settings → API in het Supabase-dashboard: de "Project URL"
    /// en de "anon public" key (NIET de "service_role" key — die is geheim).
    static let supabaseURL = "https://fqnklcabtsjopkmvgncj.supabase.co"
    static let supabaseAnonKey = "sb_publishable_ydXRxWQ23TEMGyXN9lzsxw_X7x3R_Nd"

    static var isEnabled: Bool {
        !supabaseURL.contains("YOUR-PROJECT") && !supabaseAnonKey.contains("YOUR-ANON-KEY")
    }
}


/// Eenmalige opschoning bij de overstap van Supabase naar echte CloudKit.
///
/// Elke store houdt lokaal (in UserDefaults) een setje "welke ID's zijn al
/// eens naar de cloud gesynchroniseerd" bij, om te kunnen zien of een record
/// dat er lokaal niet meer is ooit al bestond (dan is 'ie elders verwijderd)
/// of nog nooit gesynchroniseerd is (dan moet 'ie nog omhoog). Die
/// boekhouding stond nog op "al gesynchroniseerd" voor bijna alles, van toen
/// we nog Supabase gebruikten. Zonder deze opschoning zou de app bij de
/// eerste synchronisatie met de (nog lege) CloudKit-database denken dat al
/// die bestaande klanten/projecten/enzovoort ergens anders verwijderd zijn,
/// en ze dus DIRECT ook lokaal verwijderen — puur omdat de nieuwe
/// cloud-opslag nog leeg is. Deze functie wist die oude boekhouding één
/// keer, zodat alles gewoon als "nog niet gesynchroniseerd" wordt gezien en
/// netjes omhoog wordt gepusht naar CloudKit in plaats van verwijderd.
enum CloudSyncMigration {
    private static let didResetKey = "TintKing.Sync.DidResetForCloudKitMigration.v1"

    static func resetLocalSyncBookkeepingIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didResetKey) else { return }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("TintKing.Sync.") {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: didResetKey)
    }
}
