import Foundation

/// Haalt de te laat betaalde verkoopfacturen op uit Moneybird, voor het
/// compacte kaartje op het beginscherm. Bewust geen lokale opslag/sync — dit
/// is altijd een live blik op de actuele stand in Moneybird, net als
/// `testConnection`/`searchContacts` in `MoneybirdExportService`.
@MainActor
final class OverdueInvoicesStore: ObservableObject {
    @Published private(set) var invoices: [MoneybirdOverdueInvoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetchedAt: Date?

    var totalOverdueAmount: Double {
        invoices.reduce(0) { $0 + $1.totalPriceIncl }
    }

    /// Ververst de lijst. Doet niets als Moneybird nog niet is ingesteld —
    /// dan is er simpelweg nog niets te tonen, geen foutmelding nodig.
    func refresh(settings: MoneybirdSettingsStore) async {
        guard settings.isConfigured else {
            invoices = []
            lastError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // Facturen die meer dan een jaar te laat zijn, zijn in de praktijk
            // toch niet meer actueel op te volgen — die verbergen we hier,
            // zodat het kaartje relevant blijft.
            invoices = try await MoneybirdExportService.fetchOverdueInvoices(settings: settings)
                .filter { $0.daysOverdue <= 365 }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastFetchedAt = Date()
    }
}
