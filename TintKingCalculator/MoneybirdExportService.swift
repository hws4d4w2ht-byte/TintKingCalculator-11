import Foundation
import Security

/// Minimale Keychain-wrapper voor precies één geheim: het Moneybird
/// API-token. Bewust niet in UserDefaults (dat is platte tekst) — een
/// API-token geeft toegang tot je hele boekhouding, dus dat hoort in de
/// Keychain, net als een wachtwoord.
enum MoneybirdKeychain {
    private static let service = "com.tintking.calculator.moneybird"
    private static let account = "api-token"

    static func loadToken() -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    static func saveToken(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(token.utf8)
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }
}

/// Bewaart de (niet-geheime) Moneybird-instellingen in UserDefaults, en het
/// API-token apart in de Keychain. De administratie- en placeholder-klant-ID
/// staan standaard al goed ingevuld voor RS Creations / "App klant" — je
/// hoeft in de praktijk alleen zelf een API-token aan te maken en in te
/// vullen bij Instellingen.
@MainActor
final class MoneybirdSettingsStore: ObservableObject {
    @Published var administrationId: String {
        didSet { UserDefaults.standard.set(administrationId, forKey: Self.administrationKey) }
    }
    @Published var placeholderContactId: String {
        didSet { UserDefaults.standard.set(placeholderContactId, forKey: Self.contactKey) }
    }
    @Published var apiToken: String {
        didSet { MoneybirdKeychain.saveToken(apiToken) }
    }

    private static let administrationKey = "moneybird.administrationId"
    private static let contactKey = "moneybird.placeholderContactId"

    /// RS Creations-administratie waar TintKing-offertes ook al doorheen
    /// lopen (o.a. de TintKing-algemene voorwaarden zitten hier al aan
    /// offertes gekoppeld), en de speciaal aangemaakte placeholder-klant
    /// "App klant" waar geëxporteerde offertes standaard aan hangen.
    private static let defaultAdministrationId = "200641084960802265"
    private static let defaultPlaceholderContactId = "497326446576927775"

    init() {
        administrationId = UserDefaults.standard.string(forKey: Self.administrationKey) ?? Self.defaultAdministrationId
        placeholderContactId = UserDefaults.standard.string(forKey: Self.contactKey) ?? Self.defaultPlaceholderContactId
        apiToken = MoneybirdKeychain.loadToken()
    }

    var isConfigured: Bool {
        !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !administrationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !placeholderContactId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MoneybirdExportError: LocalizedError {
    case notConfigured
    case invalidResponse
    case unauthorized
    case server(Int, String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Vul eerst een Moneybird API-token in bij de Moneybird-instellingen."
        case .invalidResponse:
            return "Moneybird gaf een onverwacht antwoord terug."
        case .unauthorized:
            return "Moneybird wees het API-token af. Controleer of het token nog geldig is."
        case .server(let code, let message):
            return "Moneybird gaf een foutmelding (code \(code)): \(message)"
        case .network(let error):
            return "Kon geen verbinding maken met Moneybird: \(error.localizedDescription)"
        }
    }
}

struct MoneybirdEstimateResult {
    /// Het (interne) Moneybird-conceptnummer, zoals getoond in de lijst met concepten.
    let draftNumber: Int?
    /// Publieke weergavelink van de offerte (zoals een klant 'm zou zien).
    let viewURL: URL?
}

/// Zelfde soort resultaat, maar dan voor een concept-factuur.
struct MoneybirdInvoiceResult {
    /// Het (interne) Moneybird-conceptnummer, zoals getoond in de lijst met concepten.
    let draftNumber: Int?
    /// Publieke weergavelink van de factuur (zoals een klant 'm zou zien).
    let viewURL: URL?
}

/// Stuurt een concept-offerte of -factuur (alleen omschrijving + bedrag per
/// regel) naar Moneybird, gekoppeld aan de vaste placeholder-klant.
/// Btw-tarief en grootboekrekening laten we bewust leeg: Moneybird vult daar
/// automatisch de standaardinstelling van de administratie voor in (in de
/// praktijk 21% btw), en jij koppelt de echte klant en controleert de btw
/// zelf na in Moneybird — precies zoals afgesproken.
enum MoneybirdExportService {
    struct EstimateLine {
        var description: String
        var price: Double
    }

    /// Rondt af op hele centen voordat het bedrag naar Moneybird gaat.
    /// Zonder dit kan een deling zoals "excl. btw" (bedrag / 1,21) een lange,
    /// niet-afgeronde kommagetal opleveren (bijv. 595,041322314...), dat
    /// Moneybird dan letterlijk zo overneemt in de offerte/factuur.
    private static func roundedPrice(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Gedeelde POST-logica voor zowel offertes (`estimates.json`,
    /// sleutel "estimate") als facturen (`sales_invoices.json`, sleutel
    /// "sales_invoice") — Moneybird's API voor beide documenten is verder
    /// identiek opgebouwd.
    @MainActor
    private static func postDocument(
        endpointPath: String,
        bodyKey: String,
        lines: [EstimateLine],
        settings: MoneybirdSettingsStore,
        contactId: String? = nil
    ) async throws -> (draftNumber: Int?, viewURL: URL?) {
        guard settings.isConfigured else {
            throw MoneybirdExportError.notConfigured
        }
        guard !lines.isEmpty else {
            throw MoneybirdExportError.invalidResponse
        }

        guard let url = URL(string: "https://moneybird.com/api/v2/\(settings.administrationId)/\(endpointPath)") else {
            throw MoneybirdExportError.invalidResponse
        }

        let details = lines.map { line -> [String: Any] in
            ["description": line.description, "price": Self.roundedPrice(line.price), "amount": "1"]
        }
        // Een gekoppelde klant (via Klantgegevens) gaat naar diens eigen
        // Moneybird-contact; zonder koppeling valt het terug op de vaste
        // placeholder-klant "App klant", zoals voorheen.
        let resolvedContactId = (contactId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? settings.placeholderContactId
        let body: [String: Any] = [
            bodyKey: [
                "contact_id": resolvedContactId,
                "details_attributes": details
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MoneybirdExportError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoneybirdExportError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw MoneybirdExportError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "onbekende fout"
            throw MoneybirdExportError.server(httpResponse.statusCode, message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoneybirdExportError.invalidResponse
        }

        let draftNumber = json["draft_id"] as? Int
        let viewURL = (json["url"] as? String).flatMap(URL.init(string:))
        return (draftNumber, viewURL)
    }

    @MainActor
    static func exportEstimate(lines: [EstimateLine], settings: MoneybirdSettingsStore, contactId: String? = nil) async throws -> MoneybirdEstimateResult {
        let result = try await postDocument(endpointPath: "estimates.json", bodyKey: "estimate", lines: lines, settings: settings, contactId: contactId)
        return MoneybirdEstimateResult(draftNumber: result.draftNumber, viewURL: result.viewURL)
    }

    /// Zelfde als `exportEstimate`, maar dan als concept-factuur
    /// (`sales_invoices.json`) in plaats van een concept-offerte.
    @MainActor
    static func exportInvoice(lines: [EstimateLine], settings: MoneybirdSettingsStore, contactId: String? = nil) async throws -> MoneybirdInvoiceResult {
        let result = try await postDocument(endpointPath: "sales_invoices.json", bodyKey: "sales_invoice", lines: lines, settings: settings, contactId: contactId)
        return MoneybirdInvoiceResult(draftNumber: result.draftNumber, viewURL: result.viewURL)
    }

    /// Zoekt klanten op in Moneybird op naam/adres/e-mail, voor het koppelen
    /// van een klant in de Klantgegevens-sectie aan zijn echte Moneybird-klant.
    /// Gebruikt dezelfde API-token/administratie als de offerte/factuur-export,
    /// maar heeft de placeholder-klant niet nodig (alleen lezen).
    @MainActor
    static func searchContacts(query: String, settings: MoneybirdSettingsStore) async throws -> [MoneybirdContactLink] {
        guard !settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.administrationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MoneybirdExportError.notConfigured
        }
        guard var components = URLComponents(string: "https://moneybird.com/api/v2/\(settings.administrationId)/contacts.json") else {
            throw MoneybirdExportError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "25")
        ]
        guard let url = components.url else {
            throw MoneybirdExportError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MoneybirdExportError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoneybirdExportError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw MoneybirdExportError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "onbekende fout"
            throw MoneybirdExportError.server(httpResponse.statusCode, message)
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MoneybirdExportError.invalidResponse
        }

        return array.compactMap { dict -> MoneybirdContactLink? in
            let id: String
            if let stringId = dict["id"] as? String {
                id = stringId
            } else if let numberId = dict["id"] as? NSNumber {
                id = numberId.stringValue
            } else {
                return nil
            }

            let company = (dict["company_name"] as? String) ?? ""
            let firstname = (dict["firstname"] as? String) ?? ""
            let lastname = (dict["lastname"] as? String) ?? ""
            let personName = [firstname, lastname].filter { !$0.isEmpty }.joined(separator: " ")
            let name = !company.trimmingCharacters(in: .whitespaces).isEmpty ? company : (personName.isEmpty ? "Naamloos" : personName)

            let email = (dict["email"] as? String) ?? ""
            let phone = (dict["phone"] as? String) ?? ""
            let address1 = (dict["address1"] as? String) ?? ""
            let zipcode = (dict["zipcode"] as? String) ?? ""
            let city = (dict["city"] as? String) ?? ""
            let addressParts = [address1, [zipcode, city].filter { !$0.isEmpty }.joined(separator: " ")]
                .filter { !$0.isEmpty }
            let address = addressParts.joined(separator: ", ")

            return MoneybirdContactLink(id: id, name: name, email: email, phone: phone, address: address)
        }
    }

    /// Lichte test: haalt de administraties op die bij dit token horen. Geeft
    /// geen resultaat terug, gooit alleen een fout als het token niet klopt.
    @MainActor
    static func testConnection(settings: MoneybirdSettingsStore) async throws {
        guard !settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MoneybirdExportError.notConfigured
        }
        guard let url = URL(string: "https://moneybird.com/api/v2/administrations.json") else {
            throw MoneybirdExportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MoneybirdExportError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoneybirdExportError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw MoneybirdExportError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "onbekende fout"
            throw MoneybirdExportError.server(httpResponse.statusCode, message)
        }
    }
}

import SwiftUI

/// Instellingenscherm voor de Moneybird-koppeling: alleen het API-token hoef
/// je hier zelf in te vullen (dat maak je in Moneybird zelf aan, onder
/// Instellingen → Automatisering → API-tokens aanmaken). Administratie en
/// placeholder-klant staan al goed ingesteld.
struct MoneybirdSettingsView: View {
    @ObservedObject var settings: MoneybirdSettingsStore
    var onDone: (() -> Void)? = nil

    @State private var tokenInput: String = ""
    @State private var isTesting = false
    @State private var testResultMessage: String?
    @State private var testSucceeded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Moneybird API-token") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Maak in Moneybird zelf een API-token aan via Instellingen → Automatisering → API-tokens aanmaken, en plak het hier.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        SecureField("API-token", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif

                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Opslaan en testen")
                            }
                        }
                        .disabled(isTesting || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let testResultMessage {
                            Text(testResultMessage)
                                .font(.caption)
                                .foregroundStyle(testSucceeded ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Waar komt een export terecht") {
                    Text("Elke geëxporteerde offerte of factuur komt als concept binnen bij de vaste klant \"App klant\" in je Moneybird-administratie, met alleen de omschrijvingen en bedragen ingevuld. Jij koppelt 'm daarna zelf aan de echte klant, controleert de btw, en verstuurt 'm zelf vanuit Moneybird.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 340)
        .navigationTitle("Moneybird-instellingen")
        .onAppear { tokenInput = settings.apiToken }
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar", action: onDone)
                }
            }
        }
    }

    private func testConnection() {
        settings.apiToken = tokenInput
        isTesting = true
        testResultMessage = nil
        Task {
            do {
                try await MoneybirdExportService.testConnection(settings: settings)
                testResultMessage = "Verbinding gelukt — het token werkt."
                testSucceeded = true
            } catch {
                testResultMessage = error.localizedDescription
                testSucceeded = false
            }
            isTesting = false
        }
    }
}
