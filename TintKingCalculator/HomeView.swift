import SwiftUI
import EventKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Landingsscherm: laat de laatste handelingen in de app zien (nieuwe klant,
/// notitie of foto toegevoegd, offerte/factuur verstuurd, Moneybird-koppeling),
/// snelkoppelingen naar elk tabblad, openstaande herinneringen uit Apple
/// Herinneringen en te laat betaalde Moneybird-facturen. Gedeeld tussen Mac
/// en mobiel: op de Mac (breed scherm) een overzicht in vakken met een
/// rechterkolom voor de kleinere kaartjes, op mobiel de vertrouwde lijst
/// onder elkaar. Tikken op een activiteit springt naar het bijbehorende
/// tabblad — bij een klant-gerelateerde activiteit meteen naar die klant in
/// Klanten.
struct HomeView: View {
    @ObservedObject var activityLog: ActivityLogStore
    @Binding var selectedTab: AppTab
    @Binding var selectedCustomerID: UUID?
    @ObservedObject var reminderStore: ReminderStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var overdueInvoicesStore: OverdueInvoicesStore

    private let quickLinks: [AppTab] = [
        .aanvraag, .montage, .tint, .dechrome, .snijfolie, .roll, .meten, .producten, .prijslijst, .klanten, .kozijn,
    ]

    private var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.unitsStyle = .short
        return formatter
    }

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    var body: some View {
        Group {
            #if os(macOS)
            macDashboard
            #else
            mobileList
            #endif
        }
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            reminderStore.start()
        }
        .task {
            await overdueInvoicesStore.refresh(settings: moneybirdSettings)
        }
    }

    // MARK: - Mac: overzicht in vakken (kaarten), gebruikmakend van de brede
    // schermbreedte — links het belangrijkste (snelkoppelingen + activiteit),
    // rechts een smallere kolom met de kleinere kaartjes.

    #if os(macOS)
    private var macDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HomeCard(title: "Snel naar") {
                    quickLinksRow
                }

                HStack(alignment: .top, spacing: 20) {
                    HomeCard(title: "Laatste activiteit") {
                        activityRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 20) {
                        if !overdueInvoicesStore.invoices.isEmpty {
                            HomeCard(
                                title: "Te laat betaalde facturen",
                                titleColor: .red,
                                trailing: {
                                    Text(overdueInvoicesStore.totalOverdueAmount, format: currency)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            ) {
                                overdueInvoicesRows
                            }
                        }

                        HomeCard(
                            title: "Herinneringen",
                            trailing: {
                                if reminderStore.isLoading {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        ) {
                            remindersRows
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(24)
        }
    }
    #endif

    // MARK: - Mobiel: de vertrouwde lijst onder elkaar, past beter op een
    // smal scherm dan kolommen naast elkaar.

    #if os(iOS)
    private var mobileList: some View {
        List {
            if !overdueInvoicesStore.invoices.isEmpty {
                Section {
                    overdueInvoicesRows
                } header: {
                    HStack {
                        Label("Te laat betaalde facturen", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Spacer()
                        Text(overdueInvoicesStore.totalOverdueAmount, format: currency)
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            Section("Snel naar") {
                quickLinksRow
            }

            Section {
                remindersRows
            } header: {
                HStack {
                    Text("Herinneringen")
                    Spacer()
                    if reminderStore.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Section("Laatste activiteit") {
                activityRows
            }
        }
    }
    #endif

    // MARK: - Gedeelde inhoud (los van de lay-out eromheen), zodat Mac en
    // mobiel precies dezelfde gegevens en tik-logica gebruiken.

    private var quickLinksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(quickLinks, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.title2)
                            Text(tab.title)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(width: 84, height: 72)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Rijen voor het facturen-kaartje — bewust maar een handvol tonen
    /// (de rest achter "+ N meer"), ook al is de lijst na het filter op
    /// maximaal een jaar oud meestal al kort.
    @ViewBuilder
    private var overdueInvoicesRows: some View {
        Text("Tik op een factuur om deze te openen in Moneybird en actie te ondernemen.")
            .font(.caption2)
            .foregroundStyle(.secondary)

        ForEach(overdueInvoicesStore.invoices.prefix(5)) { invoice in
            Button {
                openInMoneybird(invoice)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invoice.contactName)
                            .foregroundStyle(.primary)
                        Text("\(invoice.daysOverdue) \(invoice.daysOverdue == 1 ? "dag" : "dagen") te laat")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(invoice.totalPriceIncl, format: currency)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(invoice.viewURL == nil ? Color.secondary.opacity(0.3) : Color.accentColor)
                        .help("Open in Moneybird")
                }
            }
            .buttonStyle(.plain)
            .disabled(invoice.viewURL == nil)
        }
        if overdueInvoicesStore.invoices.count > 5 {
            Text("+ \(overdueInvoicesStore.invoices.count - 5) meer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var remindersRows: some View {
        switch reminderStore.authorizationStatus {
        case .fullAccess:
            if reminderStore.items.isEmpty {
                Text("Geen openstaande herinneringen. 🎉")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reminderStore.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            reminderStore.complete(item)
                        } label: {
                            Image(systemName: "circle")
                        }
                        .buttonStyle(.borderless)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if let dueDate = item.dueDate {
                                Text(dueDate, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(item.isOverdue ? Color.red : Color.secondary)
                            }
                        }
                    }
                }
            }
        case .notDetermined:
            Button("Toegang tot Herinneringen geven") {
                reminderStore.requestAccess()
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Geen toegang tot Herinneringen.")
                    .foregroundStyle(.secondary)
                Button("Open instellingen") {
                    openReminderSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var activityRows: some View {
        if activityLog.entries.isEmpty {
            Text("Nog geen activiteit. Zodra je een klant toevoegt of een offerte verstuurt, zie je dat hier terug.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(activityLog.entries) { entry in
                Button {
                    if let customerID = entry.customerID {
                        selectedCustomerID = customerID
                    }
                    if let tab = entry.tab {
                        selectedTab = tab
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .foregroundStyle(.primary)
                            Text(relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func openInMoneybird(_ invoice: MoneybirdOverdueInvoice) {
        guard let url = invoice.viewURL else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private func openReminderSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

#if os(macOS)
/// Eén "vak" op het Mac-beginscherm: titel + optionele rechtse toelichting
/// (bijv. een totaalbedrag of laad-indicator) in de kop, en de inhoud
/// daaronder — dezelfde losse-kaartjes-stijl als de rest van de Mac-app.
private struct HomeCard<Trailing: View, Content: View>: View {
    let title: String
    var titleColor: Color = .primary
    let trailing: () -> Trailing
    let content: () -> Content

    // @ViewBuilder hoort hier op de init-parameters, niet op de
    // properties zelf (een result builder-attribuut werkt alleen op een
    // functieparameter of een computed property met getter) — vandaar deze
    // expliciete init in plaats van de automatische memberwise-init.
    init(
        title: String,
        titleColor: Color = .primary,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleColor = titleColor
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(titleColor)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
#endif
