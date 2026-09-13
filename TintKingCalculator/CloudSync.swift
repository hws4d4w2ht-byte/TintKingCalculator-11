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

    /// Expliciet bij naam opgevraagd (in plaats van `CKContainer.default()`).
    /// Reden: `.default()` leidt de containernaam soms af uit het eigen
    /// bundle-ID van de app ("iCloud." + bundle-ID) in plaats van de
    /// container te gebruiken die in de entitlements staat, zodra die naam
    /// niet toevallig gelijk is aan dat patroon. Bij de macOS-app
    /// ("nl.tintking.calculator") komt dat toevallig overeen met onze
    /// containernaam, maar bij de mobiele app ("nl.tintking.calculator.mobile")
    /// niet — daar probeerde `.default()` dan de niet-bestaande container
    /// "iCloud.nl.tintking.calculator.mobile" te gebruiken. Door de naam hier
    /// hard te noemen, gebruiken beide apps altijd gegarandeerd dezelfde,
    /// echt bestaande container.
    private let container = CKContainer(identifier: "iCloud.nl.tintking.calculator")
    private lazy var database = container.privateCloudDatabase

    /// Puur nog een "koffertje"-waarde: dezelfde zone-ID die elke store
    /// gebruikt om zijn CKRecords te bouwen. Hier heeft die wél echt
    /// betekenis (het is de zone waar we ook echt in lezen/schrijven).
    let zoneID = CKRecordZone.ID(zoneName: "TintKingZone", ownerName: CKCurrentUserDefaultName)

    /// CloudKit vereist dat een custom zone bestaat vóór je er records in
    /// kunt opslaan of uit kunt lezen. Dit zorgt dat we dat maar één keer
    /// per appstart hoeven te proberen in plaats van voor elke aanroep.
    private var didEnsureZone = false

    /// Laatste fout- of statusmelding van een CloudKit-aanroep, in gewone
    /// taal — puur voor diagnose (bijv. getoond in een foutmelding in de
    /// app). Wordt overschreven bij elke nieuwe aanroep.
    private(set) var lastDiagnostic: String?

    private init() {}

    /// Haalt zo veel mogelijk bruikbare details uit een CloudKit-fout, in
    /// plaats van alleen de vage standaardtekst ("The operation couldn't be
    /// completed") — zodat een foutmelding in de app ook echt zegt wat er
    /// aan de hand is.
    private func diagnosticText(for error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        var parts = ["\(ckError.localizedDescription) (code \(ckError.code.rawValue))"]
        if let reason = ckError.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            parts.append("Reden: \(reason)")
        }
        if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Onderliggend: \(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))")
        }
        if let serverMessage = ckError.userInfo["ServerErrorDescription"] as? String {
            parts.append("Server: \(serverMessage)")
        }
        return parts.joined(separator: " — ")
    }

    /// Of iCloud op dit moment bruikbaar is (ingelogd op dit apparaat, geen
    /// beperkingen zoals Schermtijd/ouderlijk toezicht, etc.).
    var isAccountAvailable: Bool {
        get async {
            do {
                let status = try await container.accountStatus()
                if status != .available {
                    lastDiagnostic = "iCloud-account niet beschikbaar (status: \(status.rawValue))"
                }
                return status == .available
            } catch {
                lastDiagnostic = "Kon iCloud-accountstatus niet opvragen: \(diagnosticText(for: error))"
                return false
            }
        }
    }

    /// Haalt alle records van een bepaald recordtype op uit de eigen zone.
    func fetchAllRecords(recordType: String) async -> [CKRecord] {
        lastDiagnostic = nil
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
            lastDiagnostic = "Ophalen uit iCloud mislukt: \(diagnosticText(for: error))"
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
                if case .failure(let error) = saveResult {
                    lastDiagnostic = "Opslaan naar iCloud mislukt: \(diagnosticText(for: error))"
                    return false
                }
            }
            return true
        } catch {
            lastDiagnostic = "Opslaan naar iCloud mislukt: \(diagnosticText(for: error))"
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
                if case .failure(let error) = deleteResult {
                    lastDiagnostic = "Verwijderen uit iCloud mislukt: \(diagnosticText(for: error))"
                    return false
                }
            }
            return true
        } catch {
            lastDiagnostic = "Verwijderen uit iCloud mislukt: \(diagnosticText(for: error))"
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
            lastDiagnostic = "Aanmaken van iCloud-zone mislukt: \(diagnosticText(for: error))"
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

// MARK: - Eenmalig herstel van data uit de oude Supabase-back-up
//
// Tijdens het testen van de overstap naar CloudKit bleek een fout in de
// synchronisatielogica (inmiddels gerepareerd hierboven) lokale data te
// verwijderen wanneer het ophalen uit iCloud even mislukte. Deze data stond
// echter nog veilig in de oude Supabase-database (die tot de overstap naar
// CloudKit alle data bijhield). Dit herstelt die back-up eenmalig terug naar
// iCloud, van waaruit alle apparaten hem weer gewoon binnenkrijgen via de
// normale synchronisatie. Draait maar op één plek (de Mac-app), gemarkeerd
// met een vlag zodat dit maar één keer gebeurt.
enum SupabaseBackupRestore {
    private static let didRestoreKey = "TintKing.Sync.DidRestoreSupabaseBackup.v1"

    private struct RecoveredRecord {
        let recordType: String
        let recordID: String
        let stringFields: [String: String]
        let dateFields: [String: String]
        let numberFields: [String: Double]
    }

    private static let records: [RecoveredRecord] = [
        RecoveredRecord(recordType: "Customer", recordID: "00F1DA9A-79E3-49B1-8E66-CD21828919CA", stringFields: ["name": "Bako", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"amount\":\"18 meter\",\"width\":\"\",\"type\":\"Avery SWF Rock Grey Gloss 1520mm\",\"note\":\"\",\"id\":\"7EB52D2B-2618-4EA3-8018-65B9C098C8EA\",\"brand\":\"\"},{\"color\":\"\",\"amount\":\"10 meter\",\"width\":\"\",\"type\":\"3M 2080 zwart gloss\",\"note\":\"\",\"id\":\"73A3D4DB-AACC-4E53-9859-0BD3BF5DB10C\",\"brand\":\"\"},{\"color\":\"\",\"amount\":\"1 rol\",\"width\":\"\",\"type\":\"3M 2080 zwart gloss in stroken\",\"note\":\"\",\"id\":\"4E22F103-77AA-4E3F-BD9A-06F7A8D47BDA\",\"brand\":\"\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "091E810F-5167-4166-8136-925B97AEACE4", stringFields: ["name": "HoHo Sloopwerken", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"id\":\"BCD421A8-721E-4C2C-BE55-A7D73697157B\",\"width\":\"\",\"amount\":\"\",\"brand\":\"\",\"color\":\"\",\"note\":\"\",\"type\":\"Avery 777-073 telemagenta\"},{\"id\":\"6AEE88B3-8E54-480A-BC02-C4B034A27A5C\",\"width\":\"\",\"amount\":\"6x\",\"brand\":\"\",\"color\":\"\",\"note\":\"\",\"type\":\"Avery Surface Cleaner\"},{\"id\":\"76315E8F-04CF-45A8-B049-266543A35D51\",\"width\":\"\",\"amount\":\"10 meter\",\"brand\":\"\",\"color\":\"\",\"note\":\"\",\"type\":\"Oracal 970RA-070M Matt Black 1525mm\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "1A2A9D8E-FBED-43EA-86DD-7E13E3D0786A", stringFields: ["name": "Wasserij Soestdijk", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"id\":\"2E1E1173-0191-4E39-A741-D9EFC6382126\",\"width\":\"\",\"amount\":\"9 meter\",\"brand\":\"\",\"color\":\"\",\"note\":\"\",\"type\":\"122cm Avery 777-043CF\"},{\"id\":\"977AE11C-DA37-4E3B-AF6A-9C4D3D970171\",\"width\":\"\",\"amount\":\"5 meter\",\"brand\":\"\",\"color\":\"\",\"note\":\"\",\"type\":\"122cm Avery 777-013CF\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "313EEDA6-ADD1-4D5A-A3D8-81A50995C945", stringFields: ["name": "Alpha", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"type\":\"Oracal 970RA-305 Geranium Red\",\"id\":\"910C2553-E340-49C1-B6AA-C515370EE42E\",\"brand\":\"\",\"amount\":\"\",\"color\":\"\",\"width\":\"\",\"note\":\"\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "38C0528B-44AC-4111-8532-FE6C59BFA4F5", stringFields: ["name": "Peters-Stoffering Vloer & Interieur B.V.", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"metamark \",\"note\":\"\",\"width\":\"\",\"id\":\"D56ECB6D-8022-4EE8-9002-48E35C3456E2\",\"color\":\"olympic\",\"amount\":\"\",\"type\":\"M7-151\"},{\"brand\":\"metamark \",\"note\":\"\",\"width\":\"\",\"id\":\"CE144F26-557B-4B19-ABEF-7F6C15580395\",\"color\":\"Lime\",\"amount\":\"\",\"type\":\"M7-16\"},{\"brand\":\"metamark \",\"note\":\"\",\"width\":\"\",\"id\":\"6B240E94-A091-448B-86F1-BA780E59AD32\",\"color\":\"Aluminium\",\"amount\":\"\",\"type\":\"M7-195\"},{\"brand\":\"metamark \",\"note\":\"\",\"width\":\"\",\"id\":\"6F7D82B7-24CA-4BDB-84B6-3B3FC914CA85\",\"color\":\"Navy\",\"amount\":\"\",\"type\":\"M7-156\"}]", "moneybirdContactJSON": "{\"name\":\"Peters-Stoffering Vloer & Interieur B.V.\",\"id\":\"494145138542511837\",\"address\":\"Zuiderloswal 37, 1216CJ Hilversum\",\"email\":\"Info@peters-stoffering.nl\",\"phone\":\"\"}"], dateFields: ["modifiedAt": "2026-09-11T05:14:34Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "47F0F54B-00A5-4154-89B9-02A60ABBAFB9", stringFields: ["name": "Opel Movano", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"\",\"note\":\"\",\"width\":\"\",\"id\":\"0BC59FAC-C1D8-4F12-A4BA-708582B99439\",\"color\":\"\",\"amount\":\"12 meter\",\"type\":\"Oracal 970-056\"},{\"brand\":\"\",\"note\":\"\",\"width\":\"\",\"id\":\"CFE5BC06-65AB-4C38-84AD-B68C56BBAF51\",\"color\":\"\",\"amount\":\"7 meter\",\"type\":\"Oracal 751-057 122cm\"},{\"brand\":\"\",\"note\":\"\",\"width\":\"\",\"id\":\"FE32E5BB-95E9-409E-9524-5473432FCF3A\",\"color\":\"\",\"amount\":\"3 meter\",\"type\":\"Oracal 751-056 122cm\"},{\"brand\":\"\",\"note\":\"\",\"width\":\"\",\"id\":\"3E24BDFF-AF00-46E0-BE66-66C58D206E00\",\"color\":\"\",\"amount\":\"5 meter\",\"type\":\"Avery 700 white 122cm\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "48802D17-CDFE-4F82-8C11-D1A99E8CE26E", stringFields: ["name": "Riool Point", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"oracal \",\"note\":\"\",\"color\":\"black matt\",\"id\":\"90695068-EF7C-4590-9A58-4B5DC0389FAD\",\"width\":\"\",\"amount\":\"\",\"type\":\"970-070\"},{\"brand\":\"avery\",\"note\":\"voor belettering\",\"color\":\"blackmatt\",\"id\":\"8DDCAFFC-0C63-49F5-B3F2-972CF63D4186\",\"width\":\"\",\"amount\":\"\",\"type\":\"721\"},{\"brand\":\"oracal\",\"note\":\"\",\"color\":\"night blue metallic\",\"id\":\"FD5D0675-48CC-4AC8-A172-1BF7C509B0C9\",\"width\":\"\",\"amount\":\"3 meter\",\"type\":\"970-196\"}]"], dateFields: ["modifiedAt": "2026-09-11T05:00:01Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "53840620-A274-4AA9-A5B6-D8E7485CBD96", stringFields: ["name": "Ben Becker", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"type\":\"Oracal 751-724 Ice Grey\",\"id\":\"0AAEFE76-7BC7-4CAA-BA9C-63D528BAE624\",\"amount\":\"6 meter\",\"width\":\"\",\"brand\":\"\",\"color\":\"\",\"note\":\"Nieuw\"},{\"type\":\"Oracal 751-026 Purple Red\",\"id\":\"7F76A147-36A1-4F45-8667-3F7CBA9284A1\",\"amount\":\"4 meter\",\"width\":\"\",\"brand\":\"\",\"color\":\"\",\"note\":\"Nieuw\"},{\"type\":\"AVR 777-032CF iA Ice Grey\",\"id\":\"F1515A63-6514-4EC7-BF5A-EAD758622C76\",\"amount\":\"\",\"width\":\"\",\"brand\":\"\",\"color\":\"\",\"note\":\"Oud\"},{\"type\":\"AVR 777-067CF iA Purple Red\",\"id\":\"3222EDF6-A16B-47F2-8B18-59765AEB54C4\",\"amount\":\"\",\"width\":\"\",\"brand\":\"\",\"color\":\"\",\"note\":\"Oud\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "69EE286F-CE77-408C-BCD3-5CB1DF39D571", stringFields: ["name": "Studio Jill", "phone": "+31 6 46106145", "generalNote": "", "foilLinesJSON": "[{\"id\":\"F1F28D47-1462-47D3-AABB-416EDEAFA3AB\",\"note\":\"\",\"width\":\"\",\"amount\":\"\",\"brand\":\"avery\",\"type\":\"\",\"color\":\"rood\\/bruin\"}]", "moneybirdContactJSON": "{\"phone\":\"\",\"email\":\"jill@studiojill.nl\",\"address\":\"Oostergracht 17-04, 3763LX Soest\",\"id\":\"370397720121181518\",\"name\":\"Studio Jill\"}"], dateFields: ["modifiedAt": "2026-09-10T14:48:14Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "8CEA549E-F086-4CD2-A6C9-908DE5B887F2", stringFields: ["name": "Wrapgear", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"id\":\"E7136043-1444-4F74-BA3A-4C4986CA8A8A\",\"type\":\"Chameleon\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"6 meter\"}]"], dateFields: ["modifiedAt": "2026-09-10T05:30:35Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "97AB88F6-C0C5-4F57-88F6-BD1DC810DBA7", stringFields: ["name": "BK Boomverzorging", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"id\":\"EF515A53-5871-46BA-A292-C5E5D8FF14EE\",\"width\":\"\",\"amount\":\"\",\"brand\":\"IP\",\"color\":\"Grass gloss\",\"note\":\"\",\"type\":\"5758\"}]", "moneybirdContactJSON": "{\"phone\":\"\",\"email\":\"Facturen@bkboomverzorging.nl\",\"address\":\"Brinkstraat 5 A, 3741AM Baarn\",\"id\":\"496598761513944312\",\"name\":\"BK Boomverzorging\"}"], dateFields: ["modifiedAt": "2026-09-11T05:25:09Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "B08CDFC7-B7F4-4400-AB5F-8FBDBCFDF2C1", stringFields: ["name": "Kamphorst", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"Avery 777-092\",\"brand\":\"\",\"id\":\"29FEFC10-2BDB-441F-BA6F-150D6608E31C\",\"amount\":\"10 meter\"},{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"Avery 777-091\",\"brand\":\"\",\"id\":\"61B41950-2A6F-4264-97C5-DC08854E8874\",\"amount\":\"5 meter\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "B1B5CEA2-1AEA-4D1B-AED0-8466087F44DC", stringFields: ["name": "Ziezo Solar", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"id\":\"BE49E3A8-9CB2-42D2-89B9-4E81A3C0789C\",\"brand\":\"\",\"color\":\"\",\"type\":\"3M 2080-G25 gloss sunflower\",\"width\":\"\",\"note\":\"\",\"amount\":\"1 rol\"},{\"id\":\"A2589387-A800-495D-B79D-F42E2FCE3A19\",\"brand\":\"\",\"color\":\"\",\"type\":\"122cm Avery 759 Dark grey\",\"width\":\"\",\"note\":\"\",\"amount\":\"10 meter\"},{\"id\":\"E4473E9A-B1F1-4CE8-A962-458DF775F57B\",\"brand\":\"\",\"color\":\"\",\"type\":\"Oracal 970-070 black\",\"width\":\"\",\"note\":\"\",\"amount\":\"10 meter\"},{\"id\":\"7AD10B4A-E04B-4E47-A83A-A7ACD0ECB396\",\"brand\":\"\",\"color\":\"\",\"type\":\"60cm transferite medium (papier)\",\"width\":\"\",\"note\":\"\",\"amount\":\"1 rol\"},{\"id\":\"1345D605-51EF-4D62-8A51-089299176DD8\",\"brand\":\"\",\"color\":\"\",\"type\":\"Avery dusted 122cm\",\"width\":\"\",\"note\":\"\",\"amount\":\"20 meter\"},{\"id\":\"09771F2E-860A-4B65-B7C9-42C7C38169EC\",\"brand\":\"\",\"color\":\"\",\"type\":\"Avery 700 glans wit 122cm\",\"width\":\"\",\"note\":\"\",\"amount\":\"10 meter\"},{\"id\":\"8D34E31E-6ACC-49AA-93B4-64D3E8308F9F\",\"brand\":\"\",\"color\":\"\",\"type\":\"3M 2080 g127\",\"width\":\"\",\"note\":\"\",\"amount\":\"9 meter\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "B3F730B8-5014-4280-9B44-7EDC11FAF11B", stringFields: ["name": "Fiat Scudo", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"970-056\",\"brand\":\"\",\"amount\":\"11 meter\",\"id\":\"A2050A0F-B06B-4D7A-9611-5AB7D458F254\"},{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"ORA,751C057\",\"brand\":\"\",\"amount\":\"5 meter\",\"id\":\"B9A41C01-AFF7-4411-B12F-70361A10BD3B\"},{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"ORA,751C056\",\"brand\":\"\",\"amount\":\"2 meter\",\"id\":\"22630B43-B10B-4090-BA78-B265256A2846\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "C31318DE-EB75-4123-B46A-ED43A6058702", stringFields: ["name": "Riwelti", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"width\":\"\",\"id\":\"5D396BEF-1BF4-4B49-B55A-D1CB8BBE54D4\",\"amount\":\"5x\",\"type\":\"Avery 784\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"width\":\"\",\"id\":\"8DFCC1EB-29D6-46C1-95B3-33884BBAC351\",\"amount\":\"\",\"type\":\"Avery 750\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"width\":\"\",\"id\":\"A40F4162-ED41-4DFC-96EA-982F28909C97\",\"amount\":\"8x\",\"type\":\"Avery 777-017\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"width\":\"\",\"id\":\"190E6F33-C30E-470C-9543-4D499FA06A43\",\"amount\":\"\",\"type\":\"Oracal 970-711 stone grey\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "C82A4B7F-950B-4C28-A0EC-2238FD9AA880", stringFields: ["name": "Total Cleaning", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"amount\":\"1 rol\",\"width\":\"\",\"type\":\"970-056\",\"note\":\"\",\"id\":\"55452727-F94C-43ED-9A4D-30F46A1A6BE9\",\"brand\":\"\"},{\"color\":\"\",\"amount\":\"4 meter\",\"width\":\"\",\"type\":\"970-057\",\"note\":\"\",\"id\":\"49338B98-B0CD-4B6F-A0D4-7F92FD20EC3D\",\"brand\":\"\"},{\"color\":\"\",\"amount\":\"3 meter\",\"width\":\"\",\"type\":\"ORA,751C057\",\"note\":\"\",\"id\":\"968C437F-A9E4-4A18-8DC0-A48C1EFEADA4\",\"brand\":\"\"},{\"color\":\"\",\"amount\":\"3 meter\",\"width\":\"\",\"type\":\"ORA,751C056\",\"note\":\"\",\"id\":\"09F57B6B-CD44-49F0-BB9B-13A6041E1EBB\",\"brand\":\"\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "DB37D13D-1227-4C61-B413-BA610391D9E4", stringFields: ["name": "Transport Care", "phone": "", "generalNote": "", "foilLinesJSON": "[]", "moneybirdContactJSON": "{\"phone\":\"\",\"email\":\"jos@transportcare.nl\",\"address\":\"Professor Kochstraat 51, 1221KE Hilversum\",\"id\":\"460353958410454562\",\"name\":\"Transport Care\"}"], dateFields: ["modifiedAt": "2026-09-11T05:08:46Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "DDAE8F88-4FC5-4DD8-AABB-CF81F8BCBD40", stringFields: ["name": "GPS Perimeter Systems B.V.", "phone": "", "generalNote": "", "foilLinesJSON": "[]", "moneybirdContactJSON": "{\"id\":\"299683912578237677\",\"name\":\"GPS Perimeter Systems B.V.\",\"phone\":\"\",\"email\":\"invoice@gps-perimeter.nl\",\"address\":\"De Chamotte 2, 4191GT Geldermalsen\"}"], dateFields: ["modifiedAt": "2026-09-08T15:05:08Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "E7060C55-03B6-4F0A-BE18-B265CF01C848", stringFields: ["name": "Verboom & van der Lans", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"E93A0A97-9593-4A02-B090-D6B5E7AC4DAB\",\"width\":\"\",\"amount\":\"\",\"type\":\"Avery 710 gold yellow\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"FD0DA167-AA17-4DD9-B412-8265B571C9D3\",\"width\":\"\",\"amount\":\"\",\"type\":\"Avery 724 cobalt blue\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "EE1D0BF0-7A57-4E12-BB23-71BE4F511898", stringFields: ["name": "Krnwt", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"Avery 700-724\",\"brand\":\"\",\"id\":\"A8F013ED-6C6F-4863-AF3C-5D1CB5C079E3\",\"amount\":\"4 meter\"},{\"color\":\"\",\"note\":\"\",\"width\":\"\",\"type\":\"Avery 700-742\",\"brand\":\"\",\"id\":\"B7B02A67-201D-4481-BF2F-8E99846B5B0F\",\"amount\":\"2 meter\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "F68E503A-6842-4EA0-AD84-24484FB17C9D", stringFields: ["name": "Striping RAM", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"B4B7A684-397C-49BA-AB52-F68AB5AAD687\",\"width\":\"\",\"amount\":\"10 meter\",\"type\":\"Oracal 970RA-070M Matt Black 1525mm\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"0EF05AAE-DB21-4E1D-B929-5709B5902926\",\"width\":\"\",\"amount\":\"10 meter\",\"type\":\"3M 2080 gloss black\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"A618B3B4-4FC2-4505-94F4-055B815470BF\",\"width\":\"\",\"amount\":\"5 meter\",\"type\":\"1080-G251 Gloss Sterling Silver\"},{\"brand\":\"\",\"note\":\"\",\"color\":\"\",\"id\":\"6F204868-BC27-449D-B963-ECC7672A564B\",\"width\":\"\",\"amount\":\"\",\"type\":\"Oracal 970-305 geranienrot\"}]"], dateFields: ["modifiedAt": "2026-09-10T14:39:22Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Customer", recordID: "F82E3DBD-85AD-4AE1-81CE-2CDFA7146D84", stringFields: ["name": "Xpel", "phone": "", "generalNote": "", "foilLinesJSON": "[{\"color\":\"\",\"id\":\"1032F2B5-73E8-40F3-B9C1-2C1A2D0A4562\",\"type\":\"XPCSB2020-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"B583E57E-AA4F-4FFD-899F-34C2352BC343\",\"type\":\"XPCSB2030-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"409F6993-57EA-49CA-BD24-FB33A94F1B4E\",\"type\":\"XPCSB2024-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"00DF9136-FE89-4295-AC8D-88E02890B78A\",\"type\":\"XPCSB0520-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"6944FB89-8AF6-44F7-BE87-515B4C77F4CB\",\"type\":\"XPCSB3530-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"57655DC5-1F7F-475C-9BFB-DBCAA403023E\",\"type\":\"XPCSB7030-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"BEC8BB8D-461A-4F76-B3C2-C6B16B08A063\",\"type\":\"XPCSB7020-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"},{\"color\":\"\",\"id\":\"E3E5EE50-8D67-49AE-A571-F425C30E2A23\",\"type\":\"XPCSB7040-100\",\"width\":\"\",\"note\":\"\",\"brand\":\"\",\"amount\":\"1x\"}]"], dateFields: ["modifiedAt": "2026-09-10T05:30:35Z"], numberFields: [:]),
        RecoveredRecord(recordType: "DechromeCalculation", recordID: "226F1C1E-DBD6-4D0E-8048-A839B9FED5C6", stringFields: ["name": "audi q4", "dataJSON": "{\"selectedPartOrder\":[\"Raamlijsten Ontchromen\",\"Dakdrails Ontchromen\",\"Deurstrips\",\"Voorbumper\",\"Achterbumper\"],\"selectedParts\":[\"Voorbumper\",\"Raamlijsten Ontchromen\",\"Dakdrails Ontchromen\",\"Deurstrips\",\"Achterbumper\"],\"createdAt\":810628620.144029,\"id\":\"226F1C1E-DBD6-4D0E-8048-A839B9FED5C6\",\"modifiedAt\":810628699.378034,\"discountFixedAmount\":0,\"manualPrices\":{\"Achterbumper\":140,\"Raamlijsten Ontchromen\":160,\"Dakdrails Ontchromen\":200,\"Voorbumper\":100,\"Deurstrips\":160},\"customParts\":{},\"discountMode\":\"Geen korting\",\"discountPercentage\":0,\"name\":\"audi q4\"}"], dateFields: ["createdAt": "2026-09-09T06:37:00Z", "modifiedAt": "2026-09-09T06:38:19Z"], numberFields: [:]),
        RecoveredRecord(recordType: "DechromeCalculation", recordID: "B2A7B536-1DD2-49DE-8D70-507626B5EA8B", stringFields: ["name": "VW Tiquan R line", "dataJSON": "{\"modifiedAt\":810630350.26445,\"discountFixedAmount\":0,\"id\":\"B2A7B536-1DD2-49DE-8D70-507626B5EA8B\",\"name\":\"VW Tiquan R line\",\"createdAt\":810630350.26445,\"selectedPartOrder\":[\"Raamlijsten Ontchromen\",\"Dakdrails Ontchromen\",\"Grill ontchromen\",\"Deurstrips\",\"Voorbumper\",\"Achterbumper\",\"Zijschermen \\/ spatbord\",\"Logo voor\",\"Logo achter\",\"Uitlaat tips Ontchromen\"],\"selectedParts\":[\"Dakdrails Ontchromen\",\"Deurstrips\",\"Grill ontchromen\",\"Raamlijsten Ontchromen\",\"Uitlaat tips Ontchromen\",\"Voorbumper\",\"Logo achter\",\"Zijschermen \\/ spatbord\",\"Logo voor\",\"Achterbumper\"],\"manualPrices\":{\"Achterbumper\":80,\"Deurstrips\":140,\"Logo achter\":50,\"Raamlijsten Ontchromen\":250,\"Dakdrails Ontchromen\":200,\"Zijschermen \\/ spatbord\":60,\"Grill ontchromen\":120,\"Logo voor\":50,\"Uitlaat tips Ontchromen\":80,\"Voorbumper\":60},\"customParts\":{},\"discountMode\":\"Geen korting\",\"discountPercentage\":0}"], dateFields: ["createdAt": "2026-09-09T07:05:50Z", "modifiedAt": "2026-09-09T07:05:50Z"], numberFields: [:]),
        RecoveredRecord(recordType: "DechromeCalculation", recordID: "E7DC730E-2E52-4DF6-B1FC-0830FC90EB17", stringFields: ["name": "", "dataJSON": "{\"customParts\":{},\"discountFixedAmount\":0,\"discountMode\":\"Geen korting\",\"modifiedAt\":810918164.277104,\"createdAt\":810918164.277104,\"discountPercentage\":0,\"manualPrices\":{\"Diffuser\":120,\"Dakdrails Ontchromen\":200,\"Deurstrips\":140,\"Grill ontchromen\":160,\"Logo pakket\":180,\"Raamlijsten Ontchromen\":250,\"Voorbumper\":140},\"name\":\"\",\"selectedParts\":[\"Raamlijsten Ontchromen\",\"Deurstrips\",\"Grill ontchromen\",\"Logo pakket\",\"Diffuser\",\"Voorbumper\",\"Dakdrails Ontchromen\"],\"selectedPartOrder\":[\"Dakdrails Ontchromen\",\"Raamlijsten Ontchromen\",\"Grill ontchromen\",\"Logo pakket\",\"Diffuser\",\"Voorbumper\",\"Deurstrips\"],\"id\":\"E7DC730E-2E52-4DF6-B1FC-0830FC90EB17\"}"], dateFields: ["createdAt": "2026-09-12T15:02:44Z", "modifiedAt": "2026-09-12T15:02:44Z"], numberFields: [:]),
        RecoveredRecord(recordType: "KozijnProject", recordID: "30091DA6-6F3C-431C-9604-3F2465AAFC8F", stringFields: ["name": "test", "kozijnenJSON": "[{\"windowsillLengthCm\":100,\"quantity\":6,\"widthCm\":240,\"secondaryProfileCm\":6,\"casementHeightCm\":100,\"frameProfileCm\":6,\"heightCm\":120,\"parts\":[{\"label\":\"Boven\",\"foilWidthCm\":8,\"lengthCm\":240,\"id\":\"178615AF-AB44-418F-87CD-517899AF1C84\"},{\"label\":\"Onder\",\"foilWidthCm\":10,\"lengthCm\":240,\"id\":\"F02948DC-997F-4806-A497-942D30DEF8C6\"},{\"label\":\"Links\",\"foilWidthCm\":5,\"lengthCm\":120,\"id\":\"4060AF35-D05C-479B-AC48-23BB4BB073B3\"},{\"label\":\"Rechts\",\"foilWidthCm\":20,\"lengthCm\":120,\"id\":\"0F862B76-6EE2-409B-82B6-24B33814B7D9\"}],\"label\":\"\",\"frameType\":\"window\",\"mullionHorizontalPosition\":\"center\",\"middleType\":\"none\",\"casementWidthCm\":80,\"casementHorizontalPosition\":\"center\",\"id\":\"0AA82238-83BD-4BB3-AF5A-7A2A29462F50\"},{\"windowsillLengthCm\":100,\"quantity\":1,\"widthCm\":240,\"secondaryProfileCm\":6,\"casementHeightCm\":100,\"frameProfileCm\":6,\"heightCm\":120,\"parts\":[{\"label\":\"Boven\",\"foilWidthCm\":8,\"lengthCm\":240,\"id\":\"052A9D8F-89A4-49CB-B294-0F9B8ECF61D3\"},{\"label\":\"Onder\",\"foilWidthCm\":8,\"lengthCm\":240,\"id\":\"9F4B28B0-3035-4926-9FB5-3F5A56119690\"},{\"label\":\"Links\",\"foilWidthCm\":8,\"lengthCm\":120,\"id\":\"D8A18E75-B47D-4719-A2D9-9D0B57BC438C\"},{\"label\":\"Rechts\",\"foilWidthCm\":8,\"lengthCm\":120,\"id\":\"2C28B9D9-069A-499D-8837-ECE24D725347\"},{\"label\":\"Middenstuk\",\"foilWidthCm\":15,\"lengthCm\":108,\"id\":\"17A7F9EC-0B8F-40B0-B583-DF5E8EEAC62D\"}],\"label\":\"\",\"frameType\":\"window\",\"mullionHorizontalPosition\":\"right\",\"middleType\":\"mullion\",\"casementWidthCm\":80,\"casementHorizontalPosition\":\"center\",\"id\":\"371AB131-9505-46DF-BB0A-2B6E737D3EB5\"}]", "linkedCustomerID": "143C195C-DFBF-4B41-BA6D-B34317FCE572"], dateFields: ["modifiedAt": "2026-09-06T18:24:03Z"], numberFields: [:]),
        RecoveredRecord(recordType: "KozijnProject", recordID: "9031582B-3581-401D-B44C-32D6A05A73D4", stringFields: ["name": "Arnhem", "kozijnenJSON": "[{\"casementHorizontalPosition\":\"center\",\"middleType\":\"mullion\",\"heightCm\":120,\"windowsillLengthCm\":100,\"widthCm\":240,\"casementWidthCm\":80,\"label\":\"Kozin 1\",\"id\":\"8B3AFD43-E01A-410B-89A4-5E11558FF8D5\",\"secondaryProfileCm\":6,\"casementHeightCm\":100,\"frameType\":\"window\",\"frameProfileCm\":6,\"mullionHorizontalPosition\":\"right\",\"parts\":[{\"lengthCm\":240,\"label\":\"Boven\",\"id\":\"E8A266A5-3BFB-4BFE-BEF4-9FAEDBD1110C\",\"foilWidthCm\":8},{\"lengthCm\":240,\"label\":\"Onder\",\"id\":\"3D055B7D-512E-4D40-9ADB-8635DCC08178\",\"foilWidthCm\":8},{\"lengthCm\":120,\"label\":\"Links\",\"id\":\"B880CDDC-12D5-4841-B4BD-7AC8B8E2CF3C\",\"foilWidthCm\":8},{\"lengthCm\":120,\"label\":\"Rechts\",\"id\":\"587BF297-C3EF-44AF-BD5C-BAF84595D6E9\",\"foilWidthCm\":8},{\"lengthCm\":108,\"label\":\"Middenstuk\",\"id\":\"BF55D261-FA3E-4717-B3F3-36E139F3F67E\",\"foilWidthCm\":14}],\"quantity\":12},{\"casementHorizontalPosition\":\"center\",\"middleType\":\"none\",\"heightCm\":240,\"windowsillLengthCm\":100,\"widthCm\":120,\"casementWidthCm\":80,\"label\":\"Deur buiten\",\"id\":\"2D9D9A94-C3BC-4E8A-9F03-87BFA3641B74\",\"secondaryProfileCm\":6,\"casementHeightCm\":100,\"frameType\":\"door\",\"frameProfileCm\":10,\"mullionHorizontalPosition\":\"center\",\"parts\":[{\"lengthCm\":120,\"label\":\"Boven\",\"id\":\"EF32EF87-371C-4AAA-9916-E31CDC4EF9AB\",\"foilWidthCm\":30},{\"lengthCm\":240,\"label\":\"Links\",\"id\":\"47995EDF-36DA-4A42-9462-7B8DFDEC8913\",\"foilWidthCm\":30},{\"lengthCm\":240,\"label\":\"Rechts\",\"id\":\"8459C447-118A-4003-BE6A-669B97A03CF8\",\"foilWidthCm\":30}],\"quantity\":1}]"], dateFields: ["modifiedAt": "2026-09-06T21:22:44Z"], numberFields: [:]),
        RecoveredRecord(recordType: "PriceList", recordID: "main", stringFields: ["tintExtrasJSON": "[{\"name\":\"Voorruit tinten\",\"category\":\"Losse ruit\",\"price\":160},{\"name\":\"Voorruit Chameleon folie\",\"category\":\"Losse ruit\",\"price\":240},{\"name\":\"Raamband \\/ Zonneband tinten\",\"category\":\"Losse ruit\",\"price\":80},{\"name\":\"Driehoekruit tinten\",\"category\":\"Losse ruit\",\"price\":20},{\"name\":\"Voorportier tinten\",\"category\":\"Losse ruit\",\"price\":60},{\"name\":\"Driehoekruit + voorportier tinten\",\"category\":\"Losse ruit\",\"price\":80},{\"name\":\"Achterportier tinten\",\"category\":\"Losse ruit\",\"price\":60},{\"name\":\"Achterportier + driehoek achterruit tinten\",\"category\":\"Losse ruit\",\"price\":80},{\"name\":\"Zijruit vast kleiner dan 50 cm tinten\",\"category\":\"Losse ruit\",\"price\":40},{\"name\":\"Zijruit vast groter dan 50 cm tinten\",\"category\":\"Losse ruit\",\"price\":50},{\"name\":\"Achterklep station\\/hatchback dubbele deur tinten\",\"category\":\"Losse ruit\",\"price\":100},{\"name\":\"Achterruit Sedan of Coupe tinten\",\"category\":\"Losse ruit\",\"price\":140},{\"name\":\"Werkbus achterruit\",\"category\":\"Werkbus\",\"price\":120},{\"name\":\"Werkbus zijruiten schuifdeuren\",\"category\":\"Werkbus\",\"price\":50}]", "dechromePartsJSON": "[{\"name\":\"Achter skirt\",\"category\":\"\",\"price\":160},{\"name\":\"Achterbumper\",\"category\":\"\",\"price\":160},{\"name\":\"Achterklep\",\"category\":\"\",\"price\":40},{\"name\":\"Beltline Ontchromen mini\",\"category\":\"\",\"price\":240},{\"name\":\"Dakdrails Ontchromen\",\"category\":\"\",\"price\":200},{\"name\":\"Deurstrips\",\"category\":\"\",\"price\":80},{\"name\":\"Diffuser\",\"category\":\"\",\"price\":120},{\"name\":\"Dorpels\",\"category\":\"\",\"price\":120},{\"name\":\"Grill omlijsting Ontchromen\",\"category\":\"\",\"price\":100},{\"name\":\"Grill ontchromen\",\"category\":\"\",\"price\":160},{\"name\":\"Handgrepen Ontchromen\",\"category\":\"\",\"price\":100},{\"name\":\"Logo achter\",\"category\":\"\",\"price\":50},{\"name\":\"Logo pakket\",\"category\":\"\",\"price\":200},{\"name\":\"Logo voor\",\"category\":\"\",\"price\":50},{\"name\":\"Raamlijsten Ontchromen\",\"category\":\"\",\"price\":250},{\"name\":\"Spiegels\",\"category\":\"\",\"price\":120},{\"name\":\"Spoiler\",\"category\":\"\",\"price\":100},{\"name\":\"Uitlaat tips Ontchromen\",\"category\":\"\",\"price\":80},{\"name\":\"Voorbumper\",\"category\":\"\",\"price\":160},{\"name\":\"Voorskirt\",\"category\":\"\",\"price\":120},{\"name\":\"Zijschermen \\/ spatbord\",\"category\":\"\",\"price\":60},{\"name\":\"logo audi voor\",\"category\":\"\",\"price\":95},{\"name\":\"logo audi achter\",\"category\":\"\",\"price\":95},{\"name\":\"mini koplamp ringen\",\"category\":\"\",\"price\":60},{\"name\":\"mini achterlichten ringen\",\"category\":\"\",\"price\":60}]", "cutFoilMaterialsJSON": "[{\"name\":\"Standaard snijfolie\",\"category\":\"\",\"price\":25}]", "tintBasePackagesJSON": "[{\"name\":\"Geen basispakket\",\"category\":\"Los samenstellen\",\"price\":0},{\"name\":\"B-Stijl Hatchback (3 deuren)\",\"category\":\"B-Stijl\",\"price\":160},{\"name\":\"B-Stijl Hatchback (5 deuren)\",\"category\":\"B-Stijl\",\"price\":220},{\"name\":\"B-Stijl Sedan\",\"category\":\"B-Stijl\",\"price\":240},{\"name\":\"B-Stijl Station\",\"category\":\"B-Stijl\",\"price\":260},{\"name\":\"B-Stijl SUV \\/ Crossover\",\"category\":\"B-Stijl\",\"price\":260},{\"name\":\"B-Stijl SUV groot\",\"category\":\"B-Stijl\",\"price\":280},{\"name\":\"B-Stijl Coupe\",\"category\":\"B-Stijl\",\"price\":220},{\"name\":\"B-Stijl Pick-up\",\"category\":\"B-Stijl\",\"price\":220},{\"name\":\"A-Stijl Hatchback (3 deuren)\",\"category\":\"A-Stijl\",\"price\":280},{\"name\":\"A-Stijl Hatchback (5 deuren)\",\"category\":\"A-Stijl\",\"price\":340},{\"name\":\"A-Stijl Sedan\",\"category\":\"A-Stijl\",\"price\":360},{\"name\":\"A-Stijl Station\",\"category\":\"A-Stijl\",\"price\":380},{\"name\":\"A-Stijl SUV \\/ Crossover\",\"category\":\"A-Stijl\",\"price\":380},{\"name\":\"A-Stijl SUV groot\",\"category\":\"A-Stijl\",\"price\":400},{\"name\":\"A-Stijl Coupe\",\"category\":\"A-Stijl\",\"price\":340},{\"name\":\"A-Stijl Pick-up\",\"category\":\"A-Stijl\",\"price\":340},{\"name\":\"Tesla Model 3 vanaf de B-stijl\",\"category\":\"Merkspecifiek\",\"price\":350},{\"name\":\"Tesla Model 3 vanaf de A-stijl\",\"category\":\"Merkspecifiek\",\"price\":470}]"], dateFields: ["modifiedAt": "2026-09-11T05:25:26Z"], numberFields: ["cutFoilMarginCm": 8.0, "cutFoilRollWidthCm": 122.0, "cutFoilStartupCost": 25.0, "cutFoilLaborPricePerM2": 25.0, "cutFoilMediumMultiplier": 2.0, "cutFoilSimpleMultiplier": 1.0, "cutFoilComplexMultiplier": 3.0, "cutFoilMinimumPricePerPiece": 0.5]),
        RecoveredRecord(recordType: "Product", recordID: "084C1B6E-8992-4964-83EB-52C653599B09", stringFields: ["name": "Navigator mini sticker custom", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 5.0]),
        RecoveredRecord(recordType: "Product", recordID: "0FF246E0-BB08-440D-B425-EC1505E5E7E9", stringFields: ["name": "Ram TRX PPF", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 80.0]),
        RecoveredRecord(recordType: "Product", recordID: "17FBBDBD-5027-45D7-A743-3818B514598F", stringFields: ["name": "3M Gold rakel met vilt", "category": "Gereedschap", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 6.51]),
        RecoveredRecord(recordType: "Product", recordID: "1A42A8E7-817F-4709-9CE6-F90C65D0B787", stringFields: ["name": "RAM Front Grille Emblem Vinyl Overlay", "category": "Logo's & emblemen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 25.0]),
        RecoveredRecord(recordType: "Product", recordID: "1B61B794-2BB6-4269-90B4-87F423E323D7", stringFields: ["name": "Stripng 6 banen RAM incl huif", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 650.0]),
        RecoveredRecord(recordType: "Product", recordID: "1E91DAB2-E33B-4942-B0FC-79036B0CC867", stringFields: ["name": "3m Ontchromen 50mm 25m", "category": "Tape", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 45.0]),
        RecoveredRecord(recordType: "Product", recordID: "2247EEAF-FEBA-4C06-9AF6-918EF1628D57", stringFields: ["name": "Tint folie 20% 1 meter", "category": "Folie", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 8.5]),
        RecoveredRecord(recordType: "Product", recordID: "25AE6FDD-2FC7-4F73-BA72-FFD84072D6E1", stringFields: ["name": "Navigator mini sticker Special", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.5]),
        RecoveredRecord(recordType: "Product", recordID: "27630E3A-A02C-43D3-A106-D08BE53D0EDF", stringFields: ["name": "RAM - Striping Twin Line Offset", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 550.0]),
        RecoveredRecord(recordType: "Product", recordID: "2813C4EC-36C5-434B-B88C-5B359852E303", stringFields: ["name": "Striping singler Line", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 550.0]),
        RecoveredRecord(recordType: "Product", recordID: "2861AB18-D857-4B50-AFB1-23CE4512686C", stringFields: ["name": "3M Knifeless Tape Finish-Line 3,5mm - 50 meter", "category": "Tape", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 30.0]),
        RecoveredRecord(recordType: "Product", recordID: "2A3C7198-BF15-4E6C-8C3F-92B771BA831B", stringFields: ["name": "Navigator pro Carbon", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 4.5]),
        RecoveredRecord(recordType: "Product", recordID: "2F29052D-66FB-43E6-A7F8-F8F99F807C12", stringFields: ["name": "Avery Cleaner + Ontvetter", "category": "Gereedschap", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 22.5]),
        RecoveredRecord(recordType: "Product", recordID: "4468D4A1-BD74-47F1-8E39-BC6B3420B9A4", stringFields: ["name": "Carwrap folie 3m 152cm", "category": "Folie", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 43.0]),
        RecoveredRecord(recordType: "Product", recordID: "48C5576D-C3D0-4CB6-BA7D-FBED908246D1", stringFields: ["name": "Navigator mini sticker", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 1.0]),
        RecoveredRecord(recordType: "Product", recordID: "4DA9124A-4BF5-4525-8242-F4519F8948B9", stringFields: ["name": "XPEL 20% 100cm", "category": "Folie", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 15.0]),
        RecoveredRecord(recordType: "Product", recordID: "4EFD6065-BD13-420C-8F22-D91A44322EE5", stringFields: ["name": "Navigator mini sticker fluor", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.0]),
        RecoveredRecord(recordType: "Product", recordID: "511BD185-D9CE-4C80-B823-D94C838FF9E9", stringFields: ["name": "Chevrolet High country - Twin Line Color Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 650.0]),
        RecoveredRecord(recordType: "Product", recordID: "52202852-7574-485D-9657-5BC667E9F5C0", stringFields: ["name": "XPEL 20% 50cm", "category": "Folie", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 7.5]),
        RecoveredRecord(recordType: "Product", recordID: "738A754B-6420-476F-B5A4-AB1C0E7F11F7", stringFields: ["name": "koplampen tinten", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 140.0]),
        RecoveredRecord(recordType: "Product", recordID: "7CE73347-911A-4FF9-9660-742156DDE55A", stringFields: ["name": "RAM Striping gekleurde bies vervangen", "category": "Striping", "description": "2 biezen", "variantGroupsJSON": "[{\"options\":[{\"priceDelta\":0,\"name\":\"rood\",\"id\":\"0E4920F5-3BB9-45FC-83B9-D0C2AF074F0B\"},{\"priceDelta\":0,\"name\":\"blauw\",\"id\":\"E9E0C7E2-7D48-444B-95CD-A018BD8BE42D\"},{\"priceDelta\":0,\"name\":\"groen\",\"id\":\"E7664A3B-E12D-41F5-AD5A-7BE2224E8431\"}],\"name\":\"Variant\",\"id\":\"B1803DE9-B2F7-4114-B35B-AB9F23E49CE0\"}]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 150.0]),
        RecoveredRecord(recordType: "Product", recordID: "86F8C2FC-8895-42E8-821A-009EF54B3719", stringFields: ["name": "Achter lichten tinten", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 100.0]),
        RecoveredRecord(recordType: "Product", recordID: "871C98D0-8AC7-4BE4-878E-EF4E5A129E16", stringFields: ["name": "RAM Striping bedcover", "category": "Striping", "description": "", "variantGroupsJSON": "[{\"options\":[],\"sharedGroupID\":\"B6D57D42-E61D-4DE5-9DFE-F0B5679031AF\",\"name\":\"\",\"id\":\"FF2BDCD0-607A-47C4-8C80-9D35E134A70A\"}]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 150.0]),
        RecoveredRecord(recordType: "Product", recordID: "8C242381-D081-490A-A945-3907296C4BBB", stringFields: ["name": "RAM Striping -Striping Twin Line", "category": "Striping", "description": "Striping 6 banen\n2 breede banen\n2 smalle banen\n2 rode biezen", "variantGroupsJSON": "[{\"id\":\"B171D5FB-5CEB-4E86-AA90-0E5F70D67771\",\"name\":\"kleur\",\"options\":[{\"name\":\"rood\",\"id\":\"0A1217D4-1078-43DA-B2FC-B5852582DFE9\",\"priceDelta\":0},{\"name\":\"blauw\",\"id\":\"772842D8-6C55-4100-AA26-13B1CB15FDB7\",\"priceDelta\":0},{\"name\":\"groe\",\"id\":\"99C928A5-CAEA-4F30-9BF3-7DF7C6A3B15F\",\"priceDelta\":0}]},{\"id\":\"DC71BF8A-2F06-480C-8607-02DF3E1E5C7F\",\"name\":\"lampen tinten\",\"options\":[{\"name\":\"koplampen\",\"id\":\"4F70B21A-8F42-4405-A75F-A8653CA7BF9F\",\"priceDelta\":150},{\"name\":\"achterlichten\",\"id\":\"CE345F56-6EC1-45A7-8C56-CB69FFBDDB5B\",\"priceDelta\":120},{\"name\":\"alles\",\"id\":\"2DA9984C-CD9A-47EF-8B49-F0286792ADEB\",\"priceDelta\":320}]}]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 600.0]),
        RecoveredRecord(recordType: "Product", recordID: "959CC73C-8B5E-4A63-A7FF-3718A4681044", stringFields: ["name": "Ram streep gril", "category": "Logo's & emblemen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 60.0]),
        RecoveredRecord(recordType: "Product", recordID: "9BB3EECB-707E-47E6-8CAE-8C9217F4AD86", stringFields: ["name": "Maverick sticker fluor", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.0]),
        RecoveredRecord(recordType: "Product", recordID: "9D6A14EC-9AEB-4FE5-95CF-EBF138DCE3CB", stringFields: ["name": "Navigator sticker", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.0]),
        RecoveredRecord(recordType: "Product", recordID: "A0061E33-9D10-4F05-8990-5A5F5CF850A5", stringFields: ["name": "Navigator sticker fluor", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.0]),
        RecoveredRecord(recordType: "Product", recordID: "A8B244F6-38AD-459C-8C94-94ED07B1AA96", stringFields: ["name": "Navigator sticker custom", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 5.0]),
        RecoveredRecord(recordType: "Product", recordID: "B0B63888-F6FB-4781-9696-37CF4307EE55", stringFields: ["name": "RAM (gen 5) - Striping Twin Line Color Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 500.0]),
        RecoveredRecord(recordType: "Product", recordID: "B48587AE-7052-4878-816A-F19AFF6E065A", stringFields: ["name": "XPEL 20% 75cm", "category": "Folie", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 11.25]),
        RecoveredRecord(recordType: "Product", recordID: "BC63986C-A6F8-4DEC-98D5-7436F8816C4C", stringFields: ["name": "GMC koplampen Eclips", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 180.0]),
        RecoveredRecord(recordType: "Product", recordID: "C175181C-D44B-4AFC-A5F5-3631A20E6377", stringFields: ["name": "Ram Logo's rondom plakken", "category": "Logo's & emblemen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 150.0]),
        RecoveredRecord(recordType: "Product", recordID: "C19B299A-57CD-4E08-92FE-A91DCD5F0568", stringFields: ["name": "Maverick sticker", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 1.0]),
        RecoveredRecord(recordType: "Product", recordID: "C692219D-ED99-4D83-9EEF-754BD0D028A3", stringFields: ["name": "Striping single line Color Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 650.0]),
        RecoveredRecord(recordType: "Product", recordID: "C9042636-40A9-47A4-9BD3-A7773AA93178", stringFields: ["name": "RAM (gen 5) - Striping Twin Line Color Detail V-Line", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 600.0]),
        RecoveredRecord(recordType: "Product", recordID: "D39908AF-8175-42F6-8560-2F2AD91B47DE", stringFields: ["name": "Sleutelhanger", "category": "Gereedschap", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 5.0]),
        RecoveredRecord(recordType: "Product", recordID: "D6DE840E-E49A-4108-979C-AA9C80F00F94", stringFields: ["name": "Ram Tinten verlichting", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 350.0]),
        RecoveredRecord(recordType: "Product", recordID: "D9DBB9EC-72EC-41FA-83D9-71411FC254ED", stringFields: ["name": "RAM (gen 4) Striping 6 banen incl bedcover", "category": "Striping", "description": "Striping 6 banen\n2 breede banen\n2 smalle banen\n2 biezen", "variantGroupsJSON": "[{\"options\":[],\"sharedGroupID\":\"B6D57D42-E61D-4DE5-9DFE-F0B5679031AF\",\"id\":\"FB356EEF-261A-4902-9B68-CA80E1EAD937\",\"name\":\"\"}]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 700.0]),
        RecoveredRecord(recordType: "Product", recordID: "DD64FDBA-E16E-49B6-BBF0-55CBA680BA47", stringFields: ["name": "Chevrolet Koplampen folie PPF (incl montage)", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 120.0]),
        RecoveredRecord(recordType: "Product", recordID: "EAA85B6A-2FC8-4CD6-A9C4-183DD4FCB216", stringFields: ["name": "RAM koplampen tinten", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 140.0]),
        RecoveredRecord(recordType: "Product", recordID: "EBD43D6B-3E93-4592-A0F9-B2020089DCE0", stringFields: ["name": "RAM (gen 4) Striping Twin Line Color Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 700.0]),
        RecoveredRecord(recordType: "Product", recordID: "ECA68C4F-75D7-4C6B-B3BD-DAE959BB3182", stringFields: ["name": "RAM Tailgate Emblem Vinyl Overlay", "category": "Logo's & emblemen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 35.0]),
        RecoveredRecord(recordType: "Product", recordID: "EED6069A-2C8B-4B0C-9692-409F9E950D46", stringFields: ["name": "RAM (gen 5) - Striping Twin Line Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 600.0]),
        RecoveredRecord(recordType: "Product", recordID: "F1734B16-428D-42A7-B312-3BCF9881B9B2", stringFields: ["name": "Chevrolet Koplampen folie PPF", "category": "Verlichting & koplampen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 80.0]),
        RecoveredRecord(recordType: "Product", recordID: "F5A93669-815C-4E04-9838-9B1DF9EFE1D3", stringFields: ["name": "Striping single Line Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 600.0]),
        RecoveredRecord(recordType: "Product", recordID: "F6B8A767-C663-4939-8DB5-C3DBF573A681", stringFields: ["name": "Navigator sticker", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 1.0]),
        RecoveredRecord(recordType: "Product", recordID: "F71C9543-F8C9-4FBE-93F1-59CCEE96E6AF", stringFields: ["name": "Navigator sticker Special", "category": "Stickers", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 2.5]),
        RecoveredRecord(recordType: "Product", recordID: "FB65DEC3-739D-406C-8859-7F619D579F52", stringFields: ["name": "Ram Hemi logo's wrap", "category": "Logo's & emblemen", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 50.0]),
        RecoveredRecord(recordType: "Product", recordID: "FC7BE016-8113-42BA-8415-1051E6E936A5", stringFields: ["name": "RAM (gen 5) Striping Twin Line Color Detail", "category": "Striping", "description": "", "variantGroupsJSON": "[]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: ["price": 600.0]),
        RecoveredRecord(recordType: "Project", recordID: "59DD56F1-07B2-42A3-A990-569F3AE51A0F", stringFields: ["inputJSON": "{\"difficulty\":\"Normaal\",\"parkingToll\":0,\"travelHours\":1,\"kilometers\":80,\"shipping\":0,\"otherDirectCosts\":0,\"risk\":\"Laag\",\"installHours\":3,\"projectName\":\"Reclamezuil  incl Montage\",\"materials\":[{\"markup\":0.3,\"name\":\"MGBzuil\",\"id\":\"7870C289-21C2-441D-8D9B-D93A801C448A\",\"cost\":653.12},{\"markup\":0,\"name\":\"belettering\",\"id\":\"9E185D8F-A8DE-45E0-91C8-B9E52A848257\",\"cost\":80},{\"markup\":0,\"name\":\"cement\",\"id\":\"EDC29EEA-6985-4378-BB1D-09FC8010B65B\",\"cost\":20}],\"rental\":0,\"prepHours\":1,\"rush\":false,\"chosenPrice\":0,\"linkedCustomerID\":\"DDAE8F88-4FC5-4DD8-AABB-CF81F8BCBD40\",\"installers\":1}", "settingsJSON": "{\"difficultyNormalPercentage\":0,\"rushPercentage\":0.15,\"riskLowPercentage\":0,\"riskHighPercentage\":0.15,\"hourlyRate\":60,\"kmRate\":0.35,\"travelHourlyRate\":25,\"difficultyVeryHardPercentage\":0.2,\"riskNormalPercentage\":0.1,\"difficultyHardPercentage\":0.1}"], dateFields: ["createdAt": "2026-09-08T15:05:48Z", "modifiedAt": "2026-09-09T09:26:15Z"], numberFields: [:]),
        RecoveredRecord(recordType: "Project", recordID: "9C1004EA-E690-49FD-BDFE-1B450102E3F6", stringFields: ["inputJSON": "{\"travelHours\":0,\"otherDirectCosts\":0,\"kilometers\":0,\"projectName\":\"Dibond bord  incl beletterin\",\"materials\":[{\"name\":\"plaat 443x48cm uit 2 delen\",\"cost\":99.83,\"markup\":0.21,\"id\":\"4A88A6AC-E1F1-46B7-9173-4EC52F6C8D0D\"},{\"name\":\"folie\",\"cost\":60,\"markup\":0.4,\"id\":\"66983C99-21C6-479A-8CFE-3A24F1E450F5\"}],\"chosenPrice\":0,\"rush\":false,\"risk\":\"Normaal\",\"parkingToll\":0,\"rental\":0,\"prepHours\":1,\"linkedCustomerID\":\"03798F84-BED3-4D83-A59F-FE76D6D04173\",\"difficulty\":\"Normaal\",\"installHours\":0,\"shipping\":0,\"installers\":1}", "settingsJSON": "{\"travelHourlyRate\":25,\"difficultyHardPercentage\":0.1,\"riskLowPercentage\":0,\"difficultyVeryHardPercentage\":0.2,\"hourlyRate\":75,\"riskNormalPercentage\":0.1,\"difficultyNormalPercentage\":0,\"rushPercentage\":0.15,\"kmRate\":0.35,\"riskHighPercentage\":0.15}"], dateFields: ["createdAt": "2026-09-09T13:09:03Z", "modifiedAt": "2026-09-09T13:19:31Z"], numberFields: [:]),
        RecoveredRecord(recordType: "RequestLine", recordID: "37918C3F-2776-475A-B8A4-F292A6DEB004", stringFields: ["category": "Ontchromen", "itemsJSON": "[{\"price\":200,\"optionBreakdown\":[],\"name\":\"Dakdrails Ontchromen\"},{\"price\":250,\"optionBreakdown\":[],\"name\":\"Raamlijsten Ontchromen\"},{\"price\":160,\"optionBreakdown\":[],\"name\":\"Grill ontchromen\"},{\"price\":180,\"optionBreakdown\":[],\"name\":\"Logo pakket\"},{\"price\":120,\"optionBreakdown\":[],\"name\":\"Diffuser\"},{\"price\":140,\"optionBreakdown\":[],\"name\":\"Voorbumper\"},{\"price\":140,\"optionBreakdown\":[],\"name\":\"Deurstrips\"}]", "vehicleLinesJSON": "[]"], dateFields: ["modifiedAt": "2026-09-12T15:01:54Z"], numberFields: ["total": 1190.0, "priceIncludesVAT": 1.0]),
        RecoveredRecord(recordType: "SharedVariantGroup", recordID: "B6D57D42-E61D-4DE5-9DFE-F0B5679031AF", stringFields: ["name": "striping optie", "optionsJSON": "[{\"name\":\"koplampen tinten\",\"priceDelta\":170,\"id\":\"8D146D6A-122C-48FF-A1F0-8A50EB0195CE\"},{\"name\":\"achterlichte\",\"priceDelta\":120,\"id\":\"5555BC7F-AECC-4852-87DB-D82644DBE71C\"},{\"name\":\"alle lampoen rondom\",\"priceDelta\":350,\"id\":\"A4961AF0-B531-40FA-8F54-5929C0E96741\"}]"], dateFields: ["modifiedAt": "2026-09-08T13:23:26Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "0A698DF3-CF53-4C55-B636-FFC3FD9A32EA", stringFields: ["name": "XPCSB3530-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "3812FEBB-648E-4EBF-8416-E71ADEA6C03B", stringFields: ["name": "XPCSB0520-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "5BF74170-B9F1-47C0-B753-8930D9E0210D", stringFields: ["name": "XPCSB2020-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "5D71D384-9E7A-4D0B-9547-622F3F1E097C", stringFields: ["name": "Oracal 970RA-070 Black gloss 1520mm", "note": "", "category": "Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "67316046-DCF5-4C8D-9C6D-0A6C7A1AF8E6", stringFields: ["name": "XPCSB7030-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "6BBEB2F9-2B49-4900-9319-62E07584E72F", stringFields: ["name": "XPCSB7040-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "7A846904-54CC-485B-8894-AA26238B52A8", stringFields: ["name": "Oracal 970RA-070G+ ProSlide Black 1520mm", "note": "", "category": "Folie", "supplier": "spandex / nautasign", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "82961C15-066B-46F2-995C-E57DBE2D424A", stringFields: ["name": "Oracal 970RA-070M+ ProSlide Black Matt 1520mm", "note": "", "category": "Folie", "supplier": "spandex / nautasign", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "8422AB76-98AD-4CA3-BB60-0CE65AEE442F", stringFields: ["name": "3M 2080-CFS12 Carbon Fiber Black 1524mm", "note": "voor visvinder-oost", "category": "Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "A06460FA-CA32-4E30-809E-48E691F4D7E2", stringFields: ["name": "XPCSB2030-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "AA3FFA0F-DB34-4154-96EB-0B6D70AEFDD6", stringFields: ["name": "6x Avery Surface Cleaner", "note": "", "category": "Vloeistoffen", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "C5882752-8C6B-44F1-BC80-72CD39BA9A60", stringFields: ["name": "XPCSB2024-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "E8AA24BF-6E73-4BED-8B90-D5FD61A77E06", stringFields: ["name": "TransferRite applicatietape 582U 100mtr. x 1220mm", "note": "", "category": "Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "F10FEA7A-615B-474C-91D5-ADFB3B2E0B4F", stringFields: ["name": "XPCSB7020-100", "note": "", "category": "Tint Folie", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
        RecoveredRecord(recordType: "SupplyItem", recordID: "F683021A-5F47-4525-B350-AAD515C41C2D", stringFields: ["name": "3M Knifeless Tape Design-Line 3,5mm - 50 meter", "note": "", "category": "Overig", "supplier": "", "orderLink": "", "articleNumber": ""], dateFields: ["modifiedAt": "2026-09-12T09:34:16Z"], numberFields: [:]),
    ]

    @MainActor
    static func restoreIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: didRestoreKey) else { return }
        let zoneID = CloudSyncCenter.shared.zoneID
        let isoFormatter = ISO8601DateFormatter()
        var ckRecords: [CKRecord] = []
        for r in records {
            let recordID = CKRecord.ID(recordName: r.recordID, zoneID: zoneID)
            let record = CKRecord(recordType: r.recordType, recordID: recordID)
            for (key, value) in r.stringFields {
                record[key] = value as NSString
            }
            for (key, value) in r.dateFields {
                if let date = isoFormatter.date(from: value) {
                    record[key] = date as NSDate
                }
            }
            for (key, value) in r.numberFields {
                record[key] = value as NSNumber
            }
            ckRecords.append(record)
        }
        guard !ckRecords.isEmpty else {
            UserDefaults.standard.set(true, forKey: didRestoreKey)
            return
        }
        // In kleine batches pushen (ruim onder CloudKit's limiet per aanroep).
        var allSucceeded = true
        for chunk in stride(from: 0, to: ckRecords.count, by: 25).map({ Array(ckRecords[$0..<min($0 + 25, ckRecords.count)]) }) {
            let ok = await CloudSyncCenter.shared.save(records: chunk)
            if !ok { allSucceeded = false }
        }
        if allSucceeded {
            UserDefaults.standard.set(true, forKey: didRestoreKey)
        }
    }
}
