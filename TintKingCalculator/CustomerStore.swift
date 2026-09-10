import Foundation
import CloudKit

/// Eén folie/materiaal-regel bij een klant, bijvoorbeeld "10 meter Oracal
/// 970RA-070M Matt Black 1525mm". Bewust losse velden mét een vrij notitieveld:
/// merken, types, kleuren en breedtes variëren te veel voor een vaste lijst, dus
/// mag alles hier ingevuld blijven zoals je het zelf noteert.
struct CustomerFoilLine: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Hoeveelheid, vrij formaat zoals je het zelf noteert: "10 meter", "3x", "1 rol".
    var amount: String = ""
    var brand: String = ""
    /// Type/artikelcode, bijv. "970RA-070M+ ProSlide" of "2080-CFS12".
    var type: String = ""
    var color: String = ""
    /// Breedte, bijv. "1520mm" of "122cm".
    var width: String = ""
    var note: String = ""

    /// Compacte weergave voor in een lijst, in dezelfde volgorde als je het kladblok
    /// oorspronkelijk noteerde.
    var displayText: String {
        [amount, brand, type, color, width]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Eén dagboek-achtige aantekening bij een klant, met optioneel foto's erbij —
/// bijvoorbeeld van een afgerond project, zodat je dat later kunt terugzien.
/// De foto's zelf staan als los bestand op schijf (zie CustomerPhotoStore), niet
/// hier in het model — dat zou de lokale opslag veel te groot maken. Hier staan
/// alleen de bestandsnamen.
struct CustomerNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var text: String = ""
    var photoFilenames: [String] = []
}

/// Een koppeling naar een bestaande klant in Moneybird (via de Moneybird-API),
/// zodat adres/e-mail/telefoon hier zichtbaar zijn zonder ze over te typen.
/// Puur een verwijzing + momentopname — de echte klantgegevens blijven in
/// Moneybird staan, dit is alleen een lokale cache van het laatste opzoekmoment.
struct MoneybirdContactLink: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var email: String = ""
    var phone: String = ""
    var address: String = ""
}

struct Customer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var phone: String = ""
    var foilLines: [CustomerFoilLine] = []
    var generalNote: String = ""
    var notes: [CustomerNote] = []
    var moneybirdContact: MoneybirdContactLink? = nil
    var modifiedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, name, phone, foilLines, generalNote, notes, moneybirdContact, modifiedAt
    }

    init(id: UUID = UUID(), name: String = "", phone: String = "", foilLines: [CustomerFoilLine] = [], generalNote: String = "", notes: [CustomerNote] = [], moneybirdContact: MoneybirdContactLink? = nil, modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.phone = phone
        self.foilLines = foilLines
        self.generalNote = generalNote
        self.notes = notes
        self.moneybirdContact = moneybirdContact
        self.modifiedAt = modifiedAt
    }

    /// Handgeschreven, in plaats van de automatisch gesynthetiseerde
    /// Decodable, zodat een `modifiedAt` dat ontbreekt in een ouder, al
    /// lokaal opgeslagen bestand (van vóór de cloud-synchronisatie) niet het
    /// hele bestand — dus alle klanten — onleesbaar maakt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        foilLines = try container.decodeIfPresent([CustomerFoilLine].self, forKey: .foilLines) ?? []
        generalNote = try container.decodeIfPresent(String.self, forKey: .generalNote) ?? ""
        notes = try container.decodeIfPresent([CustomerNote].self, forKey: .notes) ?? []
        moneybirdContact = try container.decodeIfPresent(MoneybirdContactLink.self, forKey: .moneybirdContact)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(phone, forKey: .phone)
        try container.encode(foilLines, forKey: .foilLines)
        try container.encode(generalNote, forKey: .generalNote)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(moneybirdContact, forKey: .moneybirdContact)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

extension Customer {
    /// Telefoonnummer om te gebruiken voor WhatsApp: het eigen ingevulde
    /// nummer, en anders (als deze klant gekoppeld is) het nummer dat
    /// Moneybird voor dit contact heeft. Geeft nil als er geen van beide is.
    var whatsAppPhone: String? {
        let own = phone.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        let fromMoneybird = moneybirdContact?.phone.trimmingCharacters(in: .whitespaces) ?? ""
        return fromMoneybird.isEmpty ? nil : fromMoneybird
    }
}

/// Klantgegevens met per klant een overzicht van gebruikte folie/materiaal —
/// vervangt het rommelige kladblok door een doorzoekbaar overzicht. Gedeeld
/// tussen de Mac- en de mobiele app, en gesynchroniseerd via iCloud zodra die
/// capability aan staat (zie CloudSync.swift), net als de andere stores.
@MainActor
final class CustomerStore: ObservableObject {
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private let storageKey = "TintKing.Customers.v1"
    private let syncedIDsKey = "TintKing.Sync.SyncedCustomerIDs"
    private let pendingDeletionsKey = "TintKing.Sync.PendingCustomerDeletions"

    init() {
        load()
        if customers.isEmpty {
            // Eerste keer opstarten met dit scherm: vul 'm met de klanten uit je
            // oude kladblok, zodat je niets kwijtraakt. Zodra er al een klant is
            // opgeslagen (ook op een ander apparaat, via iCloud) gebeurt dit niet
            // opnieuw.
            customers = Self.seedCustomers
            persistLocally()
        }
        Task { await syncWithCloud() }
    }

    var sortedCustomers: [Customer] {
        customers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Zoekt een klant op id, handig als je alleen een (optionele) UUID bij de
    /// hand hebt, bijvoorbeeld vanuit `RequestStore.linkedCustomerID`.
    func customer(withID id: UUID?) -> Customer? {
        guard let id else { return nil }
        return customers.first { $0.id == id }
    }

    @discardableResult
    func addCustomer(name: String) -> Customer {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let customer = Customer(name: clean.isEmpty ? "Nieuwe klant" : clean)
        customers.append(customer)
        persistLocally()
        Task { await push(customer) }
        return customer
    }

    func update(_ customer: Customer) {
        guard let index = customers.firstIndex(where: { $0.id == customer.id }) else { return }
        var updated = customer
        updated.modifiedAt = Date()
        customers[index] = updated
        persistLocally()
        Task { await push(updated) }
    }

    func delete(_ customer: Customer) {
        CustomerPhotoStore.deleteAllPhotos(for: customer)
        customers.removeAll { $0.id == customer.id }
        persistLocally()
        addPendingDeletion(customer.id)
        Task { await flushPendingDeletions() }
    }

    // MARK: - Duplicaten opschonen

    /// Groepeert klanten op (getrimde, hoofdletterongevoelige) naam en geeft
    /// alleen de namen terug die meer dan één keer voorkomen — bijvoorbeeld
    /// doordat de Mac- en mobiele app ooit los van elkaar (vóór er
    /// cloud-synchronisatie was) allebei met dezelfde beginlijst met klanten
    /// zijn gestart, elk met hun eigen interne ID's. Zodra synchronisatie
    /// voor het eerst aanstaat, komen die als "verschillende" klanten samen.
    var duplicateGroups: [[Customer]] {
        let grouped = Dictionary(grouping: customers) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return grouped.values.filter { $0.count > 1 && !$0[0].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Voegt klanten met dezelfde naam samen tot één klant: folie/materiaal-regels,
    /// notities, telefoonnummer en Moneybird-koppeling worden gecombineerd (niets
    /// gaat verloren), waarna de overbodige duplicaten worden verwijderd — ook uit
    /// de cloud, via de bestaande verwijder-functie. Geeft het aantal verwijderde
    /// duplicaten terug.
    @discardableResult
    func mergeDuplicates() -> Int {
        var removedCount = 0
        for group in duplicateGroups {
            // Meeste inhoud eerst, zodat bijv. een Moneybird-koppeling of
            // uitgebreide notitie niet per ongeluk als "extra" wordt gezien.
            let sortedByContent = group.sorted { lhs, rhs in
                let lhsScore = lhs.foilLines.count + lhs.notes.count + (lhs.phone.isEmpty ? 0 : 1) + (lhs.moneybirdContact == nil ? 0 : 1)
                let rhsScore = rhs.foilLines.count + rhs.notes.count + (rhs.phone.isEmpty ? 0 : 1) + (rhs.moneybirdContact == nil ? 0 : 1)
                return lhsScore > rhsScore
            }
            guard var merged = sortedByContent.first else { continue }
            let others = Array(sortedByContent.dropFirst())

            var seenFoilLines = Set(merged.foilLines.map(\.displayText))
            for other in others {
                for line in other.foilLines where !seenFoilLines.contains(line.displayText) {
                    merged.foilLines.append(line)
                    seenFoilLines.insert(line.displayText)
                }
                if merged.phone.isEmpty { merged.phone = other.phone }
                if merged.moneybirdContact == nil { merged.moneybirdContact = other.moneybirdContact }
                merged.notes.append(contentsOf: other.notes)
                if merged.generalNote.isEmpty {
                    merged.generalNote = other.generalNote
                } else if !other.generalNote.isEmpty, !merged.generalNote.contains(other.generalNote) {
                    merged.generalNote += "\n" + other.generalNote
                }
            }

            update(merged)
            for duplicate in others {
                delete(duplicate)
                removedCount += 1
            }
        }
        return removedCount
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Customer].self, from: data) else { return }
        customers = decoded
    }

    private func persistLocally() {
        guard let data = try? JSONEncoder().encode(customers) else { return }
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

    /// Haalt de laatste stand uit iCloud op, voegt klanten van andere apparaten toe,
    /// werkt gewijzigde klanten bij, en verwijdert klanten die elders zijn verwijderd.
    func syncWithCloud() async {
        guard await CloudSyncCenter.shared.isAccountAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flushPendingDeletions()

        let remoteRecords = await CloudSyncCenter.shared.fetchAllRecords(recordType: Customer.recordType)
        let remoteCustomers = remoteRecords.compactMap(Customer.init(record:))
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCustomers.map { ($0.id, $0) })

        var localByID = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        var currentSyncedIDs = syncedIDs
        var idsToPush: [UUID] = []
        var changed = false

        for remote in remoteCustomers {
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
            customers = Array(localByID.values)
            persistLocally()
        }

        for id in idsToPush {
            if let customer = localByID[id] {
                await push(customer)
            }
        }

        lastSyncedAt = Date()
    }

    private func push(_ customer: Customer) async {
        let record = customer.toCKRecord(zoneID: CloudSyncCenter.shared.zoneID)
        if await CloudSyncCenter.shared.save(records: [record]) {
            var synced = syncedIDs
            synced.insert(customer.id)
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

private extension Customer {
    static let recordType = "Customer"

    func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["phone"] = phone as NSString
        record["generalNote"] = generalNote as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        if let data = try? JSONEncoder().encode(foilLines), let json = String(data: data, encoding: .utf8) {
            record["foilLinesJSON"] = json as NSString
        }
        if let contact = moneybirdContact, let data = try? JSONEncoder().encode(contact), let json = String(data: data, encoding: .utf8) {
            record["moneybirdContactJSON"] = json as NSString
        }
        if !notes.isEmpty, let data = try? JSONEncoder().encode(notes), let json = String(data: data, encoding: .utf8) {
            record["notesJSON"] = json as NSString
        }
        return record
    }

    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let modifiedAt = record["modifiedAt"] as? Date,
            let foilLinesJSON = record["foilLinesJSON"] as? String,
            let foilLinesData = foilLinesJSON.data(using: .utf8),
            let foilLines = try? JSONDecoder().decode([CustomerFoilLine].self, from: foilLinesData)
        else { return nil }
        let phone = (record["phone"] as? String) ?? ""
        let generalNote = (record["generalNote"] as? String) ?? ""
        var notes: [CustomerNote] = []
        if let notesJSON = record["notesJSON"] as? String, let notesData = notesJSON.data(using: .utf8) {
            notes = (try? JSONDecoder().decode([CustomerNote].self, from: notesData)) ?? []
        }
        var moneybirdContact: MoneybirdContactLink? = nil
        if let contactJSON = record["moneybirdContactJSON"] as? String, let contactData = contactJSON.data(using: .utf8) {
            moneybirdContact = try? JSONDecoder().decode(MoneybirdContactLink.self, from: contactData)
        }
        self.init(id: id, name: name, phone: phone, foilLines: foilLines, generalNote: generalNote, notes: notes, moneybirdContact: moneybirdContact, modifiedAt: modifiedAt)
    }
}

// MARK: - Seed vanuit het oude kladblok

extension CustomerStore {
    /// Elke klant hier heeft bewust een vast, hardgecodeerd ID (niet het
    /// standaard willekeurige `UUID()`) — anders krijgt elk toestel dat ooit
    /// met een lege klantenlijst opstart (bijv. na een herinstallatie) zijn
    /// eigen, andere ID's voor dezelfde namen, en komen die na synchronisatie
    /// als "verschillende" klanten naast elkaar te staan. Met een vast ID
    /// wordt een hernieuwde seed altijd als dezelfde klant herkend.
    static let seedCustomers: [Customer] = [
        Customer(id: UUID(uuidString: "7E8382FD-02DC-40E0-98F6-EF1BF13A0F53")!, name: "Striping RAM", foilLines: [
            CustomerFoilLine(amount: "10 meter", type: "Oracal 970RA-070M Matt Black 1525mm"),
            CustomerFoilLine(amount: "10 meter", type: "3M 2080 gloss black"),
            CustomerFoilLine(amount: "5 meter", type: "1080-G251 Gloss Sterling Silver"),
            CustomerFoilLine(amount: "", type: "Oracal 970-305 geranienrot"),
        ]),
        Customer(id: UUID(uuidString: "F393F770-43CD-4801-AD06-31127EBCF40F")!, name: "Ziezo Solar", foilLines: [
            CustomerFoilLine(amount: "1 rol", type: "3M 2080-G25 gloss sunflower"),
            CustomerFoilLine(amount: "10 meter", type: "122cm Avery 759 Dark grey"),
            CustomerFoilLine(amount: "10 meter", type: "Oracal 970-070 black"),
            CustomerFoilLine(amount: "1 rol", type: "60cm transferite medium (papier)"),
            CustomerFoilLine(amount: "20 meter", type: "Avery dusted 122cm"),
            CustomerFoilLine(amount: "10 meter", type: "Avery 700 glans wit 122cm"),
            CustomerFoilLine(amount: "9 meter", type: "3M 2080 g127"),
        ]),
        Customer(id: UUID(uuidString: "911B0C9D-30F8-4F36-B090-483A063F2962")!, name: "Bako", foilLines: [
            CustomerFoilLine(amount: "18 meter", type: "Avery SWF Rock Grey Gloss 1520mm"),
            CustomerFoilLine(amount: "10 meter", type: "3M 2080 zwart gloss"),
            CustomerFoilLine(amount: "1 rol", type: "3M 2080 zwart gloss in stroken"),
        ]),
        Customer(id: UUID(uuidString: "A2CFF70A-501A-454E-B971-3C168BB541CC")!, name: "Total Cleaning", foilLines: [
            CustomerFoilLine(amount: "1 rol", type: "970-056"),
            CustomerFoilLine(amount: "4 meter", type: "970-057"),
            CustomerFoilLine(amount: "3 meter", type: "ORA,751C057"),
            CustomerFoilLine(amount: "3 meter", type: "ORA,751C056"),
        ]),
        Customer(id: UUID(uuidString: "F251B1F7-3CFC-4C37-A664-7A7B9EFFCB66")!, name: "Fiat Scudo", foilLines: [
            CustomerFoilLine(amount: "11 meter", type: "970-056"),
            CustomerFoilLine(amount: "5 meter", type: "ORA,751C057"),
            CustomerFoilLine(amount: "2 meter", type: "ORA,751C056"),
        ]),
        Customer(id: UUID(uuidString: "C02ACAE9-5377-4521-860D-C73F48C9BC63")!, name: "Opel Movano", foilLines: [
            CustomerFoilLine(amount: "12 meter", type: "Oracal 970-056"),
            CustomerFoilLine(amount: "7 meter", type: "Oracal 751-057 122cm"),
            CustomerFoilLine(amount: "3 meter", type: "Oracal 751-056 122cm"),
            CustomerFoilLine(amount: "5 meter", type: "Avery 700 white 122cm"),
        ]),
        Customer(id: UUID(uuidString: "55C5787B-B298-45CF-82A9-CFA9A8953CB8")!, name: "Riwelti", foilLines: [
            CustomerFoilLine(amount: "5x", type: "Avery 784"),
            CustomerFoilLine(amount: "", type: "Avery 750"),
            CustomerFoilLine(amount: "8x", type: "Avery 777-017"),
            CustomerFoilLine(amount: "", type: "Oracal 970-711 stone grey"),
        ]),
        Customer(id: UUID(uuidString: "5F670330-9233-4793-922D-4A0E8E37BF4C")!, name: "Xpel", foilLines: [
            CustomerFoilLine(amount: "1x", type: "XPCSB2020-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB2030-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB2024-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB0520-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB3530-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB7030-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB7020-100"),
            CustomerFoilLine(amount: "1x", type: "XPCSB7040-100"),
        ]),
        Customer(id: UUID(uuidString: "6757BF02-E72D-407C-A526-9C7FD2E9C0F0")!, name: "Wrapgear", foilLines: [
            CustomerFoilLine(amount: "6 meter", type: "Chameleon"),
        ]),
        Customer(id: UUID(uuidString: "6AC4629B-7A7D-49B0-97AE-6B57D771BDD7")!, name: "Kamphorst", foilLines: [
            CustomerFoilLine(amount: "10 meter", type: "Avery 777-092"),
            CustomerFoilLine(amount: "5 meter", type: "Avery 777-091"),
        ]),
        Customer(id: UUID(uuidString: "87B21348-75D6-43E7-86CF-EAE716FE9714")!, name: "Verboom & van der Lans", foilLines: [
            CustomerFoilLine(amount: "", type: "Avery 710 gold yellow"),
            CustomerFoilLine(amount: "", type: "Avery 724 cobalt blue"),
        ]),
        Customer(id: UUID(uuidString: "72CBBEF7-4C3C-4C9E-8469-AE3EA27DC9EA")!, name: "Ben Becker", foilLines: [
            CustomerFoilLine(amount: "6 meter", type: "Oracal 751-724 Ice Grey", note: "Nieuw"),
            CustomerFoilLine(amount: "4 meter", type: "Oracal 751-026 Purple Red", note: "Nieuw"),
            CustomerFoilLine(amount: "", type: "AVR 777-032CF iA Ice Grey", note: "Oud"),
            CustomerFoilLine(amount: "", type: "AVR 777-067CF iA Purple Red", note: "Oud"),
        ]),
        Customer(id: UUID(uuidString: "8A375E38-6B65-4F5D-B2B1-CD0088977064")!, name: "Krnwt", foilLines: [
            CustomerFoilLine(amount: "4 meter", type: "Avery 700-724"),
            CustomerFoilLine(amount: "2 meter", type: "Avery 700-742"),
        ]),
        Customer(id: UUID(uuidString: "54856142-A05C-40BB-B562-514388DA9A84")!, name: "Alpha", foilLines: [
            CustomerFoilLine(amount: "", type: "Oracal 970RA-305 Geranium Red"),
        ]),
        Customer(id: UUID(uuidString: "5036B310-FDF4-4DFB-8C67-CA445FA4DDFE")!, name: "Wasserij Soestdijk", foilLines: [
            CustomerFoilLine(amount: "9 meter", type: "122cm Avery 777-043CF"),
            CustomerFoilLine(amount: "5 meter", type: "122cm Avery 777-013CF"),
        ]),
        Customer(id: UUID(uuidString: "9389890C-86B1-4063-8289-7FB387EB0A73")!, name: "HoHo Sloopwerken", foilLines: [
            CustomerFoilLine(amount: "", type: "Avery 777-073 telemagenta"),
            CustomerFoilLine(amount: "6x", type: "Avery Surface Cleaner"),
            CustomerFoilLine(amount: "10 meter", type: "Oracal 970RA-070M Matt Black 1525mm"),
        ]),
    ]
}

// MARK: - Foto-opslag voor klantnotities

/// Bewaart foto's bij klantnotities als losse JPEG-bestanden in de lokale
/// Application Support-map, niet in UserDefaults — dat zou veel te groot en
/// traag worden zodra er een paar foto's bij komen. Het klantmodel bewaart
/// alleen de bestandsnamen (zie CustomerNote.photoFilenames). Let op: dit is
/// puur lokale opslag; zolang iCloud-sync uitstaat blijven foto's op het
/// apparaat waar ze zijn toegevoegd.
enum CustomerPhotoStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TintKingCalculator/KlantFotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Slaat de foto op en geeft de bestandsnaam terug om in een CustomerNote te bewaren.
    @discardableResult
    static func save(_ data: Data) -> String {
        let filename = "\(UUID().uuidString).jpg"
        try? data.write(to: url(for: filename))
        return filename
    }

    static func load(_ filename: String) -> Data? {
        try? Data(contentsOf: url(for: filename))
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    static func deleteAllPhotos(for customer: Customer) {
        for note in customer.notes {
            for filename in note.photoFilenames {
                delete(filename)
            }
        }
    }
}
