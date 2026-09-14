import SwiftUI
import EventKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Landingsscherm: laat zien wat er vandaag toe doet — de agenda van
/// vandaag, openstaande herinneringen uit Apple Herinneringen en te laat
/// betaalde Moneybird-facturen — met de laatste app-activiteit bewust klein
/// onderaan (geheugensteuntje, geen hoofdmoot). Gedeeld tussen Mac en
/// mobiel: op de Mac (breed scherm) drie even brede kaarten naast elkaar,
/// op mobiel de vertrouwde lijst onder elkaar. Tikken op een activiteit
/// springt naar het bijbehorende tabblad — bij een klant-gerelateerde
/// activiteit meteen naar die klant in Klanten.
struct HomeView: View {
    @ObservedObject var activityLog: ActivityLogStore
    @Binding var selectedTab: AppTab
    @Binding var selectedCustomerID: UUID?
    @ObservedObject var reminderStore: ReminderStore
    @ObservedObject var calendarStore: CalendarStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @ObservedObject var overdueInvoicesStore: OverdueInvoicesStore

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
            calendarStore.start()
        }
        .task {
            await overdueInvoicesStore.refresh(settings: moneybirdSettings)
        }
    }

    // MARK: - Mac: drie even brede kaarten naast elkaar (agenda,
    // herinneringen, te laat betaalde facturen) — het belangrijkste van de
    // dag in één oogopslag, met de tabbladen al bereikbaar via de menubalk
    // erboven. Laatste activiteit staat bewust klein en apart onderaan.

    #if os(macOS)
    private var macDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    HomeCard(title: "Agenda vandaag") {
                        agendaRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !overdueInvoicesStore.invoices.isEmpty {
                        HomeCard(
                            title: "Te laat betaalde facturen",
                            titleColor: .red,
                            trailing: {
                                Text(overdueInvoicesStore.totalOverdueAmount, format: currency)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        ) {
                            overdueInvoicesRows
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Bewust klein en onopvallend gehouden — dit is een
                // geheugensteuntje, geen kaartje dat om aandacht vraagt zoals
                // de agenda/herinneringen/facturen hierboven.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Laatste activiteit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    activityRowsCompact
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

            Section("Agenda vandaag") {
                agendaRows
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(invoice.contactName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("\(invoice.daysOverdue) \(invoice.daysOverdue == 1 ? "dag" : "dagen") te laat")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(invoice.totalPriceIncl, format: currency)
                        .font(.body)
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

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.body)
                            if let dueDate = item.dueDate {
                                Text(dueDate, format: .dateTime.day().month().hour().minute())
                                    .font(.subheadline)
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
    private var agendaRows: some View {
        switch calendarStore.authorizationStatus {
        case .fullAccess:
            if calendarStore.items.isEmpty {
                Text("Geen afspraken vandaag.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendarStore.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.body)
                            if let location = item.location, !location.isEmpty {
                                Text(location)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if item.isAllDay {
                            Text("Hele dag")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(item.startDate, format: .dateTime.hour().minute())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .notDetermined:
            Button("Toegang tot Agenda geven") {
                calendarStore.requestAccess()
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Geen toegang tot Agenda.")
                    .foregroundStyle(.secondary)
                Button("Open instellingen") {
                    openCalendarSettings()
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

    #if os(macOS)
    /// Kleine, ingetogen versie van `activityRows` voor onderaan het
    /// Mac-dashboard — bewust maar een handvol regels, kleine tekst, geen
    /// kaartje eromheen, zodat het niet met de belangrijkere kaarten
    /// erboven concurreert.
    @ViewBuilder
    private var activityRowsCompact: some View {
        if activityLog.entries.isEmpty {
            Text("Nog geen activiteit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(activityLog.entries.prefix(4)) { entry in
                Button {
                    if let customerID = entry.customerID {
                        selectedCustomerID = customerID
                    }
                    if let tab = entry.tab {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: entry.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(entry.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

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

    private func openCalendarSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(titleColor)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
#endif
