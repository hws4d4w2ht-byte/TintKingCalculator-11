import Foundation
import CloudKit

/// Centrale configuratie voor cloud-synchronisatie. Wordt gebruikt door
/// ProjectStore, PriceListStore, DechromePresetStore en CustomerStore, op
/// zowel de Mac- als de mobiele app.
///
/// Draait sinds september 2026 op Supabase (een simpele cloud-database via
/// HTTPS) in plaats van CloudKit/iCloud — dat laatste vereist een actief
/// Apple Developer Program-lidmaatschap, en dat is nog niet geregeld. Zodra
/// dat er wel is kan dit alsnog naar CloudKit overgezet worden, maar voor nu
/// werkt Supabase precies zo goed voor het doel (je eigen apparaten synced
/// houden) en heeft het geen speciale Apple-capability nodig.
///
/// `CKRecord`/`CKRecord.ID`/`CKRecordZone.ID` (uit CloudKit) worden hier
/// alleen nog gebruikt als simpel, in-memory "koffertje" om een record in te
/// vervoeren tussen de stores en deze klasse — er wordt geen enkele keer
/// echt met een `CKContainer`/`CKDatabase` gepraat, dus dit heeft geen
/// iCloud-capability of entitlement nodig. Dat is bewust zo gehouden: zo
/// hoefden ProjectStore.swift, CustomerStore.swift, PriceListStore.swift en
/// DechromePresetStore.swift geen letter aangepast te worden voor deze omzetting.
enum SupabaseSyncConfig {
    /// Vul deze twee in met de gegevens van je Supabase-project: Project
    /// Settings → API in het Supabase-dashboard. De eerste is de "Project
    /// URL" (bijv. "https://abcdefgh.supabase.co"), de tweede is de "anon
    /// public" key (NIET de "service_role" key — die is geheim).
    ///
    /// Zolang deze op de placeholder-waarden staan, blijft synchronisatie
    /// gewoon uitgeschakeld en werkt de app volledig lokaal door, precies
    /// zoals voorheen met `CloudSyncConfig.isEnabled = false`.
    static let supabaseURL = "https://fqnklcabtsjopkmvgncj.supabase.co"
    static let supabaseAnonKey = "sb_publishable_ydXRxWQ23TEMGyXN9lzsxw_X7x3R_Nd"

    static var isEnabled: Bool {
        !supabaseURL.contains("YOUR-PROJECT") && !supabaseAnonKey.contains("YOUR-ANON-KEY")
    }
}

/// Lichte, generieke wrapper die de vier stores gebruiken om records te lezen
/// en te schrijven. Faalt een aanroep (geen internet, Supabase nog niet
/// ingesteld), dan geeft deze klasse dat netjes terug zonder te crashen — de
/// app blijft gewoon lokaal werken. Publieke interface is bewust identiek
/// gebleven aan de oude CloudKit-versie, zodat de stores die 'm gebruiken
/// ongewijzigd konden blijven.
final class CloudSyncCenter {
    static let shared = CloudSyncCenter()

    /// Puur nog een "koffertje"-waarde voor `CKRecord.ID`-constructie — heeft
    /// geen betekenis meer voor Supabase zelf (er is geen echte CloudKit-zone).
    let zoneID = CKRecordZone.ID(zoneName: "TintKingZone", ownerName: CKCurrentUserDefaultName)

    private let tableName = "sync_records"
    private let session = URLSession.shared
    private let isoFormatter = ISO8601DateFormatter()

    private init() {}

    /// Of synchronisatie op dit moment bruikbaar is. Bij Supabase betekent dat
    /// simpelweg: is er een echte URL/key ingevuld (geen accountstatus zoals
    /// bij iCloud nodig).
    var isAccountAvailable: Bool {
        get async { SupabaseSyncConfig.isEnabled }
    }

    /// Haalt alle records van een bepaald recordtype op.
    func fetchAllRecords(recordType: String) async -> [CKRecord] {
        guard SupabaseSyncConfig.isEnabled else { return [] }
        guard let url = buildURL(queryItems: [
            URLQueryItem(name: "record_type", value: "eq.\(recordType)"),
            URLQueryItem(name: "select", value: "record_id,fields"),
        ]) else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyHeaders(to: &req)

        do {
            let (data, response) = try await session.data(for: req)
            guard isSuccess(response) else { return [] }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard
                    let recordID = row["record_id"] as? String,
                    let fields = row["fields"] as? [String: Any]
                else { return nil }
                return decodeRecord(recordType: recordType, recordName: recordID, fields: fields)
            }
        } catch {
            // Geen verbinding, of Supabase (tijdelijk) niet bereikbaar: lokale
            // data blijft leidend.
            return []
        }
    }

    /// Slaat records op (maakt aan of overschrijft, op basis van record_type + record_id).
    @discardableResult
    func save(records: [CKRecord]) async -> Bool {
        guard SupabaseSyncConfig.isEnabled else { return false }
        guard !records.isEmpty else { return true }
        guard let url = buildURL(queryItems: [
            URLQueryItem(name: "on_conflict", value: "record_type,record_id"),
        ]) else { return false }

        let rows: [[String: Any]] = records.map { record in
            [
                "record_type": record.recordType,
                "record_id": record.recordID.recordName,
                "fields": encodeFields(record),
                "modified_at": isoFormatter.string(from: Date()),
            ]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: rows) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyHeaders(to: &req)
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = body

        do {
            let (_, response) = try await session.data(for: req)
            return isSuccess(response)
        } catch {
            return false
        }
    }

    /// Verwijdert records op basis van hun record_id (identiek, ongeacht type
    /// — veilig omdat elke store een echte UUID als naam gebruikt en die dus
    /// nooit toevallig samenvallen tussen bijv. Project en Customer).
    @discardableResult
    func delete(recordIDs: [CKRecord.ID]) async -> Bool {
        guard SupabaseSyncConfig.isEnabled else { return false }
        guard !recordIDs.isEmpty else { return true }
        let names = recordIDs.map(\.recordName)
        let quoted = names.map { "\"\($0)\"" }.joined(separator: ",")
        guard let url = buildURL(queryItems: [
            URLQueryItem(name: "record_id", value: "in.(\(quoted))"),
        ]) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyHeaders(to: &req)

        do {
            let (_, response) = try await session.data(for: req)
            return isSuccess(response)
        } catch {
            return false
        }
    }

    func recordID(name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: - HTTP-hulpjes

    private func buildURL(queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: SupabaseSyncConfig.supabaseURL) else { return nil }
        components.path = "/rest/v1/\(tableName)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(SupabaseSyncConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseSyncConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - CKRecord <-> JSON

    /// Zet de velden van een CKRecord om naar een JSON-vriendelijke
    /// dictionary, met een klein type-label erbij (date/number/string) zodat
    /// `decodeRecord` het bij het terughalen weer als het juiste native type
    /// (NSDate/NSNumber/NSString) kan zetten — CKRecord accepteert namelijk
    /// alleen die specifieke types, en zonder het label zou een teruggehaald
    /// getal of datum per ongeluk als losse string eindigen.
    private func encodeFields(_ record: CKRecord) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let value as Date:
                result[key] = ["t": "date", "v": isoFormatter.string(from: value)]
            case let value as NSNumber:
                result[key] = ["t": "number", "v": value.doubleValue]
            case let value as String:
                result[key] = ["t": "string", "v": value]
            default:
                break
            }
        }
        return result
    }

    private func decodeRecord(recordType: String, recordName: String, fields: [String: Any]) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(name: recordName))
        for (key, raw) in fields {
            guard let entry = raw as? [String: Any], let type = entry["t"] as? String else { continue }
            switch type {
            case "date":
                if let string = entry["v"] as? String, let date = isoFormatter.date(from: string) {
                    record[key] = date as NSDate
                }
            case "number":
                if let number = entry["v"] as? Double {
                    record[key] = number as NSNumber
                }
            case "string":
                if let string = entry["v"] as? String {
                    record[key] = string as NSString
                }
            default:
                break
            }
        }
        return record
    }
}
