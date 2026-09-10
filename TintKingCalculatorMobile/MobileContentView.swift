import SwiftUI
import UIKit

// MARK: - Gedeelde stijl en onderdelen voor de mobiele schermen
//
// De macOS-app heeft zijn eigen (private) versies van dit soort hulpweergaven in
// ContentView.swift. Omdat ContentView.swift geen deel uitmaakt van dit mobiele
// target, staan hier losse, mobiel-vriendelijke varianten die door alle mobiele
// schermen (Tinten, Ontchromen, Aanvraag) gedeeld worden.

let mobileCurrency: FloatingPointFormatStyle<Double>.Currency = .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))

struct MobileCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func mobileCardStyle() -> some View {
        modifier(MobileCardModifier())
    }
}

/// Voertuiggegevens-kaart, gebruikt boven zowel de Tint- als de Ontchroom-calculator.
struct MobileVehicleInfoCard: View {
    @ObservedObject var store: RequestStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voertuig").font(.headline)
                Spacer()
                Button(role: .destructive) {
                    store.clearVehicleInfo()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            Text("Dit voertuig wordt vastgelegd zodra je op 'Toevoegen aan aanvraag' tikt — zo kun je meerdere auto's na elkaar toevoegen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Merk", text: $store.vehicleBrand)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $store.vehicleModel)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Carrosserie", selection: $store.vehicleBodyType) {
                    Text("Kies carrosserie").tag("")
                    ForEach(carBodyTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .pickerStyle(.menu)
                TextField("Bouwjaar", text: $store.vehicleYear)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
        }
    }
}

/// Rij met omhoog/omlaag-knoppen, gebruikt in de samenvattingen om de volgorde
/// van geselecteerde onderdelen aan te passen (net als op de Mac).
struct MobileReorderButtons: View {
    var canMoveUp: Bool
    var canMoveDown: Bool
    var moveUp: () -> Void
    var moveDown: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: moveUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)

            Button(action: moveDown) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
        }
    }
}

/// Korting-sectie, identiek aan de Mac-versie maar als losse herbruikbare view.
struct MobileDiscountSection: View {
    @Binding var mode: DiscountMode
    @Binding var percentage: Double
    @Binding var fixedAmount: Double

    var body: some View {
        Picker("Korting", selection: $mode) {
            ForEach(DiscountMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)

        if mode == .percentage {
            HStack {
                Text("Korting")
                Spacer()
                AppNumberField(placeholder: "0", value: $percentage)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("%")
            }
        } else if mode == .fixed {
            HStack {
                Text("Korting")
                Spacer()
                AppNumberField(placeholder: "0", value: $fixedAmount)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 85)
                Text("€")
            }
        }
    }
}

/// Kopieer- en toevoegknoppen onder iedere calculator, verticaal gestapeld
/// zodat ze goed passen op de smalle iPhone-breedte.
struct MobileActionButtons: View {
    var whatsAppText: () -> String
    /// Optioneel: telefoonnummer van de gekoppelde klant, voor als WhatsApp
    /// direct geopend kan worden in plaats van dat er gekopieerd moet worden.
    var whatsAppPhone: (() -> String?)? = nil
    var emailText: () -> String
    var addToRequest: () -> Void
    var addDisabled: Bool

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if let phone = whatsAppPhone?(), let url = WhatsAppLink.url(phone: phone, message: whatsAppText()) {
                    UIApplication.shared.open(url)
                } else {
                    UIPasteboard.general.string = whatsAppText()
                }
            } label: {
                Label("Kopieer voor WhatsApp", systemImage: "message.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                UIPasteboard.general.string = emailText()
            } label: {
                Label("Kopieer voor e-mail", systemImage: "envelope.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                addToRequest()
            } label: {
                Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.green)
            .disabled(addDisabled)
        }
        .padding(.top, 2)
    }
}

/// Klein label + waarde-blokje, gebruikt in de resultaatoverzichten.
struct MobileMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MobileCurrencyField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            AppNumberField(placeholder: "0,00", value: $value, decimals: 2...2)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text("€").foregroundStyle(.secondary)
        }
    }
}

struct MobileNumberField: View {
    let title: String
    let suffix: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            AppNumberField(placeholder: "0", value: $value)
                .multilineTextAlignment(.trailing)
                .frame(width: 75)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
}

struct MobilePercentageField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            AppNumberField(placeholder: "0", value: Binding(
                get: { value * 100 },
                set: { value = $0 / 100 }
            ), decimals: 0...0)
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            Text("%").foregroundStyle(.secondary)
        }
    }
}

struct MobileContentView: View {
    @StateObject private var requestStore = RequestStore()
    @StateObject private var priceListStore = PriceListStore()
    @StateObject private var measurementStore = MeasurementStore()
    @StateObject private var moneybirdSettings = MoneybirdSettingsStore()
    @StateObject private var productStore = ProductStore()
    @StateObject private var customerStore = CustomerStore()
    @StateObject private var supplyStore = SupplyStore()
    @StateObject private var orderListStore = OrderListStore()
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var quoteArchiveStore = QuoteArchiveStore()
    @StateObject private var reminderStore = ReminderStore()
    @ObservedObject private var activityLog = ActivityLogStore.shared
    @State private var selectedTab: AppTab = .home
    @State private var selectedCustomerID: UUID?
    @State private var selectedMontageProjectID: UUID?
    @StateObject private var tabOrderStore = TabOrderStore()

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(tabOrderStore.order, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.mobileTabTitle, systemImage: tab.mobileTabImage)
                    }
                    .tag(tab)
            }
        }
        .tint(.green)
    }

    /// Geeft het scherm terug dat bij een tabblad hoort. Losgetrokken van de
    /// vaste volgorde hierboven, zodat de tabbladen zelf herschikbaar zijn via
    /// TabOrderStore/TabOrderView zonder dat de inhoud per tab hoeft te
    /// veranderen.
    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                HomeView(activityLog: activityLog, selectedTab: $selectedTab, selectedCustomerID: $selectedCustomerID, reminderStore: reminderStore)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink {
                                TabOrderView(store: tabOrderStore)
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }
                        }
                    }
            }
        case .montage:
            NavigationStack {
                MobileMontageView(store: projectStore, moneybirdSettings: moneybirdSettings, customerStore: customerStore)
                    .navigationDestination(item: $selectedMontageProjectID) { projectID in
                        MobileMontageEditorView(store: projectStore, projectID: projectID, moneybirdSettings: moneybirdSettings, customerStore: customerStore)
                    }
            }
        case .tint:
            NavigationStack {
                MobileTintView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
            }
        case .dechrome:
            NavigationStack {
                MobileDechromeView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
            }
        case .producten:
            NavigationStack {
                ProductListView(store: productStore, requestStore: requestStore)
            }
        case .aanvraag:
            NavigationStack {
                MobileRequestView(store: requestStore, moneybirdSettings: moneybirdSettings, customerStore: customerStore, quoteArchiveStore: quoteArchiveStore)
            }
        case .roll:
            NavigationStack {
                MobileRollCalculatorView()
            }
        case .snijfolie:
            NavigationStack {
                MobileSnijfolieView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
            }
        case .meten:
            NavigationStack {
                MeasureView(store: measurementStore)
            }
        case .prijslijst:
            NavigationStack {
                PriceListView(store: priceListStore)
            }
        case .klanten:
            CustomerView(store: customerStore, moneybirdSettings: moneybirdSettings, orderListStore: orderListStore, projectStore: projectStore, quoteArchiveStore: quoteArchiveStore, selectedCustomerID: $selectedCustomerID, selectedTab: $selectedTab, selectedMontageProjectID: $selectedMontageProjectID)
        case .bestellijst:
            NavigationStack {
                SupplyView(store: supplyStore, orderListStore: orderListStore)
            }
        case .kozijn:
            NavigationStack {
                KozijnCalculatorView(customerStore: customerStore, moneybirdSettings: moneybirdSettings)
            }
        }
    }
}
