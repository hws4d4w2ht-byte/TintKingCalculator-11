import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bestellijst: spullen die Robin zelf regelmatig bestelt (folie,
/// vloeistoffen, doeken, ...). Zelfde opzet als ProductListView: een
/// compacte, per categorie gegroepeerde lijst waarin je in één oogopslag
/// ziet wat je nodig hebt, met een potlood-icoon om te bewerken en een
/// prullenbak om te verwijderen — bewust geen uitgebreid detailscherm.
/// Categorieën zijn vrije tekst, zelf aan te maken via de "+"-knop bij het
/// bewerken van een artikel. Gedeeld tussen Mac en mobiel.
struct SupplyView: View {
    @ObservedObject var store: SupplyStore
    @ObservedObject var orderListStore: OrderListStore

    @State private var editingItem: SupplyItem?
    @State private var itemPendingDeletion: SupplyItem?
    @State private var showAddSheet = false
    @State private var categoryFilter: String?
    @State private var selectedIDs: Set<UUID> = []

    @State private var newOrderText = ""
    @State private var showClearOrderConfirm = false
    @State private var selectedOrderIDs: Set<UUID> = []

    private var groupedItems: [(category: String, items: [SupplyItem])] {
        let grouped = Dictionary(grouping: store.sortedItems) { item -> String in
            let trimmed = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Overig" : trimmed
        }
        return grouped.keys.sorted().map { key in
            (category: key, items: grouped[key]!)
        }
    }

    private var filteredGroupedItems: [(category: String, items: [SupplyItem])] {
        guard let categoryFilter else { return groupedItems }
        return groupedItems.filter { $0.category == categoryFilter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                syncStatusRow
                orderListCard

                if !selectedIDs.isEmpty {
                    selectionBar
                }

                if groupedItems.count > 1 {
                    categoryFilterBar
                }

                if store.items.isEmpty {
                    ContentUnavailableView(
                        "Nog geen artikelen",
                        systemImage: "shippingbox",
                        description: Text("Voeg hierboven een artikel toe dat je vaak bestelt.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if filteredGroupedItems.isEmpty {
                    ContentUnavailableView(
                        "Geen artikelen in deze categorie",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Kies hierboven een andere categorie, of \"Alles\".")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(filteredGroupedItems, id: \.category) { group in
                        categorySection(group.category, group.items)
                    }
                }
            }
            .padding(16)
        }
        .withKeyboardDismiss()
        .navigationTitle("Bestellijst")
        .sheet(isPresented: $showAddSheet) {
            SupplyEditSheet(store: store, item: nil)
        }
        .sheet(item: $editingItem) { item in
            SupplyEditSheet(store: store, item: item)
        }
        .confirmationDialog(
            "Artikel verwijderen",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { isPresented in if !isPresented { itemPendingDeletion = nil } }
            ),
            presenting: itemPendingDeletion
        ) { item in
            Button("Verwijder \"\(item.displayText)\"", role: .destructive) {
                store.delete(item)
                selectedIDs.remove(item.id)
                itemPendingDeletion = nil
            }
            Button("Annuleer", role: .cancel) { itemPendingDeletion = nil }
        } message: { item in
            Text("Weet je zeker dat je \"\(item.displayText)\" wilt verwijderen? Dit kan niet ongedaan worden gemaakt.")
        }
        .confirmationDialog(
            "Bestellijst wissen",
            isPresented: $showClearOrderConfirm
        ) {
            Button("Wis alle regels", role: .destructive) {
                orderListStore.clear()
                selectedOrderIDs.removeAll()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Weet je zeker dat je alle regels in je kladblok-bestellijst wilt wissen? Handig nadat je de bestelling verstuurd hebt. Dit kan niet ongedaan worden gemaakt.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: "shippingbox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Bestellijst").font(.title2.bold())
                Text("Spullen die je vaak bestelt — folie, vloeistoffen, doeken — zodat je ze snel terugvindt bij je leveranciers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Label("Nieuw artikel", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Synchronisatiestatus + handmatige "Synchroniseer nu"-knop, in dezelfde
    /// stijl als bij Producten, Prijslijst en Projecten.
    private var syncStatusRow: some View {
        HStack(spacing: 6) {
            if store.isSyncing {
                ProgressView().controlSize(.small)
                Text("Synchroniseren…")
            } else if let lastSyncedAt = store.lastSyncedAt {
                Image(systemName: "checkmark.icloud")
                Text("Gesynchroniseerd \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            } else {
                Image(systemName: "icloud.slash")
                Text("Nog niet gesynchroniseerd")
            }
            Spacer()
            Button {
                Task { await store.syncWithCloud() }
            } label: {
                Label("Synchroniseer nu", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Kladblok voor de bestelling die je nu aan het samenstellen bent: vrij
    /// getypte regels die je met de pijltjes in de gewenste volgorde zet
    /// (bijv. per leverancier bij elkaar), en die je in één keer als platte
    /// tekst kunt kopiëren om in een e-mail te plakken. Los van de
    /// naslaglijst hieronder — die blijft staan, dit is je "kladje" voor nu.
    private var orderListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mijn bestellijst", systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                if !orderListStore.items.isEmpty {
                    Button {
                        copyOrderList()
                    } label: {
                        Label(
                            selectedOrderIDs.isEmpty ? "Kopieer alles" : "Kopieer (\(selectedOrderIDs.count))",
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        showClearOrderConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Kladblok voor je huidige bestelling — voeg hieronder handmatig producten toe (of via het winkelwagentje-icoon bij een artikel hieronder), zet ze met de pijltjes in de juiste volgorde, en kopieer de lijst om in een e-mail te plakken. Vink losse regels aan om alleen die te kopiëren (bijv. per leverancier) — zonder selectie kopieer je de hele lijst.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !selectedOrderIDs.isEmpty {
                HStack {
                    Text("\(selectedOrderIDs.count) geselecteerd")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Wis selectie") { selectedOrderIDs.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            HStack(spacing: 8) {
                TextField("Product toevoegen, bijv. \"5 meter Oracal 970 zwart\"", text: $newOrderText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addOrderItem() }
                Button {
                    addOrderItem()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(newOrderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if orderListStore.items.isEmpty {
                Text("Nog niets toegevoegd.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(orderListStore.items.enumerated()), id: \.element.id) { index, item in
                        orderItemRow(item, index: index)
                        if item.id != orderListStore.items.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func orderItemRow(_ item: OrderListItem, index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                toggleOrderSelection(item)
            } label: {
                Image(systemName: selectedOrderIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedOrderIDs.contains(item.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)

            VStack(spacing: 0) {
                Button {
                    orderListStore.move(id: item.id, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button {
                    orderListStore.move(id: item.id, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == orderListStore.items.count - 1)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField(
                "",
                text: Binding(
                    get: { item.text },
                    set: { orderListStore.update(id: item.id, text: $0) }
                )
            )
            .textFieldStyle(.plain)

            Button(role: .destructive) {
                orderListStore.delete(id: item.id)
                selectedOrderIDs.remove(item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private func addOrderItem() {
        orderListStore.add(text: newOrderText)
        newOrderText = ""
    }

    private func toggleOrderSelection(_ item: OrderListItem) {
        if selectedOrderIDs.contains(item.id) {
            selectedOrderIDs.remove(item.id)
        } else {
            selectedOrderIDs.insert(item.id)
        }
    }

    /// Kopieert de kladblok-bestellijst als platte tekst naar het klembord,
    /// één regel per artikel, in de volgorde zoals je 'm hebt gezet. Zijn er
    /// regels aangevinkt, dan gaan alleen die mee (handig om bijv. alleen de
    /// regels van één leverancier te kopiëren); zonder selectie gaat de hele
    /// lijst mee.
    private func copyOrderList() {
        let items = selectedOrderIDs.isEmpty
            ? orderListStore.items
            : orderListStore.items.filter { selectedOrderIDs.contains($0.id) }
        let text = items.map(\.text).joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selectedIDs.count) geselecteerd")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Wis selectie") {
                selectedIDs.removeAll()
            }
            .buttonStyle(.borderless)
            Button {
                copySelected()
            } label: {
                Label("Kopieer", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Zet de geselecteerde artikelen om in platte tekst (per categorie
    /// gegroepeerd, net als op het scherm) en kopieert die naar het
    /// klembord, zodat je 'm zo in een mail kunt plakken.
    private func copySelected() {
        let items = store.sortedItems.filter { selectedIDs.contains($0.id) }
        let text = copyText(for: items)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func copyText(for items: [SupplyItem]) -> String {
        let grouped = Dictionary(grouping: items) { item -> String in
            let trimmed = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Overig" : trimmed
        }
        var lines: [String] = []
        for category in grouped.keys.sorted() {
            lines.append(category)
            let sortedItems = (grouped[category] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for item in sortedItems {
                lines.append("- \(item.displayText)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggleSelection(_ item: SupplyItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(title: "Alles", isSelected: categoryFilter == nil) {
                    categoryFilter = nil
                }
                ForEach(groupedItems.map(\.category), id: \.self) { category in
                    filterChip(title: category, isSelected: categoryFilter == category) {
                        categoryFilter = category
                    }
                }
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderless)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
    }

    private func categorySection(_ category: String, _ items: [SupplyItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category).font(.headline)
            ForEach(items) { item in
                supplyRow(item)
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func supplyRow(_ item: SupplyItem) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleSelection(item)
            } label: {
                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)

            Button {
                editingItem = item
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                itemPendingDeletion = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayText)
                    .lineLimit(1)
                    .textSelection(.enabled)
                let subtitle = [item.supplier, item.articleNumber]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Button {
                let supplier = item.supplier.trimmingCharacters(in: .whitespacesAndNewlines)
                orderListStore.add(text: supplier.isEmpty ? item.displayText : "\(item.displayText) — \(supplier)")
            } label: {
                Image(systemName: "cart.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Voeg toe aan mijn bestellijst")

            if let url = item.orderURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SupplyEditSheet: View {
    @ObservedObject var store: SupplyStore
    let item: SupplyItem?

    @State private var name: String
    @State private var category: String
    @State private var supplier: String
    @State private var articleNumber: String
    @State private var orderLink: String
    @State private var note: String
    @State private var showNewCategoryPrompt = false
    @State private var newCategoryInput = ""
    @Environment(\.dismiss) private var dismiss

    init(store: SupplyStore, item: SupplyItem?) {
        self.store = store
        self.item = item
        _name = State(initialValue: item?.name ?? "")
        _category = State(initialValue: item?.category ?? "Folie")
        _supplier = State(initialValue: item?.supplier ?? "")
        _articleNumber = State(initialValue: item?.articleNumber ?? "")
        _orderLink = State(initialValue: item?.orderLink ?? "")
        _note = State(initialValue: item?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Artikel") {
                    TextField("Naam", text: $name)
                    categoryPicker
                }
                Section("Bestellen") {
                    TextField("Leverancier", text: $supplier)
                    TextField("Artikelnummer / SKU", text: $articleNumber)
                    TextField("Bestel-link (URL)", text: $orderLink)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                Section("Notitie") {
                    TextField("Extra opmerking (optioneel)", text: $note, axis: .vertical)
                }
            }
            .withKeyboardDismiss()
            .navigationTitle(item == nil ? "Nieuw artikel" : "Artikel bewerken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Nieuwe categorie", isPresented: $showNewCategoryPrompt) {
                TextField("Naam van de categorie", text: $newCategoryInput)
                Button("Toevoegen") {
                    let trimmed = newCategoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        category = trimmed
                    }
                    newCategoryInput = ""
                }
                Button("Annuleer", role: .cancel) {
                    newCategoryInput = ""
                }
            } message: {
                Text("Deze naam wordt gebruikt zodra je het artikel opslaat.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    /// Dropdown met bestaande categorieën, plus een "+"-knop om zelf een
    /// nieuwe, nog niet bestaande categorie toe te voegen.
    @ViewBuilder
    private var categoryPicker: some View {
        HStack(spacing: 6) {
            Menu {
                if store.categories.isEmpty {
                    Text("Nog geen categorieën")
                } else {
                    ForEach(store.categories, id: \.self) { option in
                        Button {
                            category = option
                        } label: {
                            if category == option {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(category.isEmpty ? "Categorie" : category)
                        .foregroundStyle(category.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)

            Button {
                newCategoryInput = ""
                showNewCategoryPrompt = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Nieuwe categorie toevoegen")
        }
    }

    private func save() {
        var updated = item ?? SupplyItem()
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.supplier = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.articleNumber = articleNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.orderLink = orderLink.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if item == nil {
            store.add(updated)
        } else {
            store.update(updated)
        }
    }
}
