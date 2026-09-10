import SwiftUI
import EventKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Landingsscherm: laat de laatste handelingen in de app zien (nieuwe klant,
/// notitie of foto toegevoegd, offerte/factuur verstuurd, Moneybird-koppeling),
/// snelkoppelingen naar elk tabblad en een sectie met openstaande
/// herinneringen uit Apple Herinneringen. Tikken op een activiteit springt
/// naar het bijbehorende tabblad — bij een klant-gerelateerde activiteit
/// meteen naar die klant in Klanten. Gedeeld tussen Mac en mobiel.
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

    var body: some View {
        List {
            overdueInvoicesSection

            Section("Snel naar") {
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

            remindersSection

            Section("Laatste activiteit") {
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

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    /// Compact kaartje: alleen zichtbaar als Moneybird is ingesteld én er
    /// daadwerkelijk te laat betaalde facturen zijn — anders geen extra
    /// rommel op het beginscherm. Tikken op een factuur opent 'm in Moneybird.
    @ViewBuilder
    private var overdueInvoicesSection: some View {
        if !overdueInvoicesStore.invoices.isEmpty {
            Section {
                ForEach(overdueInvoicesStore.invoices.prefix(3)) { invoice in
                    Button {
                        if let url = invoice.viewURL {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #else
                            UIApplication.shared.open(url)
                            #endif
                        }
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
                        }
                    }
                    .buttonStyle(.plain)
                }
                if overdueInvoicesStore.invoices.count > 3 {
                    Text("+ \(overdueInvoicesStore.invoices.count - 3) meer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    }

    @ViewBuilder
    private var remindersSection: some View {
        Section {
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
