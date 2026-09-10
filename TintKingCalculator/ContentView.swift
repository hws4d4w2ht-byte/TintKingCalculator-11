import SwiftUI
import AppKit

private enum TintKingTheme {
    static let cornerRadius: CGFloat = 16
}

struct TintKingCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TintKingTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TintKingTheme.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 5)
    }
}

struct TintKingHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct VehicleInfoCard: View {
    @ObservedObject var store: RequestStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voertuig").font(.headline)
                Spacer()
                Button {
                    store.clearVehicleInfo()
                } label: {
                    Label("Wis voertuig", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            Text("Dit voertuig wordt vastgelegd op het moment dat je op 'Toevoegen aan aanvraag' klikt — zo kun je meerdere auto's na elkaar toevoegen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Merk", text: $store.vehicleBrand)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $store.vehicleModel)
                    .textFieldStyle(.roundedBorder)
            }
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
            }
        }
        .cardStyle()
    }
}

struct ContentView: View {
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
    @StateObject private var overdueInvoicesStore = OverdueInvoicesStore()
    @ObservedObject private var activityLog = ActivityLogStore.shared
    @State private var selectedTab: AppTab = .home
    @State private var selectedCustomerID: UUID?
    @State private var selectedMontageProjectID: UUID?
    @StateObject private var desktopTabOrderStore = DesktopTabOrderStore()

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(desktopTabOrderStore.order, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        tabLabel(for: tab)
                    }
                    .tag(tab)
            }
        }
        .tint(.green)
        .frame(minWidth: 1050, minHeight: 720)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.green.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// Geeft het scherm terug dat bij een tabblad hoort, losgetrokken van de
    /// vaste volgorde zodat de tabbladen zelf herschikbaar zijn via
    /// DesktopTabOrderStore/DesktopTabOrderView (net als op mobiel).
    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                HomeView(activityLog: activityLog, selectedTab: $selectedTab, selectedCustomerID: $selectedCustomerID, reminderStore: reminderStore, moneybirdSettings: moneybirdSettings, overdueInvoicesStore: overdueInvoicesStore)
                    .toolbar {
                        ToolbarItem {
                            NavigationLink {
                                DesktopTabOrderView(store: desktopTabOrderStore)
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }
                        }
                    }
            }
        case .montage:
            MontageCalculatorView(store: projectStore, moneybirdSettings: moneybirdSettings, customerStore: customerStore, selectedMontageProjectID: $selectedMontageProjectID)
        case .tint:
            TintCalculatorView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
        case .dechrome:
            DechromeCalculatorView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
        case .roll:
            RollCalculatorView()
        case .snijfolie:
            SnijfolieCalculatorView(requestStore: requestStore, priceListStore: priceListStore, customerStore: customerStore, moneybirdSettings: moneybirdSettings)
        case .meten:
            NavigationStack {
                MeasureView(store: measurementStore)
            }
        case .producten:
            ProductListView(store: productStore, requestStore: requestStore)
        case .aanvraag:
            CombinedRequestView(store: requestStore, moneybirdSettings: moneybirdSettings, customerStore: customerStore, quoteArchiveStore: quoteArchiveStore)
        case .prijslijst:
            PriceListView(store: priceListStore)
        case .klanten:
            CustomerView(store: customerStore, moneybirdSettings: moneybirdSettings, orderListStore: orderListStore, projectStore: projectStore, quoteArchiveStore: quoteArchiveStore, selectedCustomerID: $selectedCustomerID, selectedTab: $selectedTab, selectedMontageProjectID: $selectedMontageProjectID)
        case .bestellijst:
            SupplyView(store: supplyStore, orderListStore: orderListStore)
        case .kozijn:
            KozijnCalculatorView(customerStore: customerStore, moneybirdSettings: moneybirdSettings)
        }
    }

    /// Geeft het label voor een tabblad terug. Home en Aanvraag tonen alleen
    /// het icoon (zonder tekst), zodat de tabbalk compacter wordt; de andere
    /// tabbladen behouden tekst + icoon zoals voorheen.
    @ViewBuilder
    private func tabLabel(for tab: AppTab) -> some View {
        switch tab {
        case .home, .aanvraag:
            Image(systemName: tab.desktopTabImage)
        default:
            Label(tab.desktopTabTitle, systemImage: tab.desktopTabImage)
        }
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(TintKingCardModifier())
    }
}
