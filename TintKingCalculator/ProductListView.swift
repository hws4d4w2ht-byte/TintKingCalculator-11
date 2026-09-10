import SwiftUI

/// Productenlijst (folie, striping, schoonmaakmiddelen, enz.) met CSV-back-up
/// en de mogelijkheid om geselecteerde producten direct aan de Aanvraag toe te
/// voegen. Gedeeld tussen Mac en mobiel, net als PriceListView. Op de Mac een
/// compacte twee-koloms lay-out (producten links, winkelwagen rechts); op
/// mobiel blijft alles onder elkaar staan.
struct ProductListView: View {
    @ObservedObject var store: ProductStore
    @ObservedObject var requestStore: RequestStore

    @State private var newName = ""
    @State private var newCategory = ""
    @State private var newDescription = ""
    @State private var newVariantGroups: [ProductVariantGroup] = []
    @State private var newPrice: Double = 0

    @State private var editingProduct: ProductItem?
    @State private var editName = ""
    @State private var editCategory = ""
    @State private var editDescription = ""
    @State private var editVariantGroups: [ProductVariantGroup] = []
    @State private var editPrice: Double = 0

    @State private var quantities: [UUID: Int] = [:]
    @State private var notes: [UUID: String] = [:]
    /// Gekozen optie per product en per submenu-groep (product-id -> groep-id -> optie-id).
    @State private var selectedVariants: [UUID: [UUID: UUID]] = [:]
    @State private var selectedCategory: String?

    @State private var showSubmenuConfigurator = false
    @State private var editingSharedGroup: SharedVariantGroup?
    @State private var sharedGroupDraftName = ""
    @State private var sharedGroupDraftOptions: [ProductVariantOption] = []

    @State private var showNewCategoryPrompt = false
    @State private var newCategoryInput = ""
    @State private var newCategoryTarget: Binding<String>?
    @State private var productPendingDeletion: ProductItem?

    @State private var showSettingsSheet = false
    @State private var showExporter = false
    @State private var exportDocument = PriceListCSVDocument(csv: "")
    @State private var showImporter = false
    @State private var pendingImport: ProductData?
    @State private var showImportConfirm = false
    @State private var importErrorMessage: String?
    @State private var importSuccessMessage: String?

    private var currency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: "EUR").locale(Locale(identifier: "nl_NL"))
    }

    private var groupedProducts: [(category: String, items: [ProductItem])] {
        let grouped = Dictionary(grouping: store.products) { product -> String in
            let trimmed = product.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Overig" : trimmed
        }
        return grouped.keys.sorted().map { key in
            (category: key, items: grouped[key]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    /// `groupedProducts`, beperkt tot de gekozen categorie (of alles als er
    /// geen categorie is geselecteerd) — voor het categoriefilter bovenaan.
    private var filteredGroupedProducts: [(category: String, items: [ProductItem])] {
        guard let selectedCategory else { return groupedProducts }
        return groupedProducts.filter { $0.category == selectedCategory }
    }

    /// Eén geselecteerd product met aantal — apart van `QuoteItem` bijgehouden
    /// zodat we per product ook nog een vrije notitie (bijv. kenteken of
    /// gebruikte folie-kleur) kunnen koppelen, vóórdat dit een regel in de
    /// aanvraag wordt.
    private struct SelectedLine: Identifiable {
        let product: ProductItem
        let quantity: Int
        var id: UUID { product.id }
    }

    private var selectedLines: [SelectedLine] {
        store.products.compactMap { product in
            guard let qty = quantities[product.id], qty > 0 else { return nil }
            return SelectedLine(product: product, quantity: qty)
        }
    }

    /// Bouwt de uiteindelijke regelnaam: aantal en eventuele notitie (bijv.
    /// "Tint folie 20% 1 meter ×2 — kenteken AB-123-C") worden aan de
    /// productnaam toegevoegd zodra dit een regel in de aanvraag wordt.
    private func quoteItem(for line: SelectedLine) -> QuoteItem {
        var name = line.quantity > 1 ? "\(line.product.name) ×\(line.quantity)" : line.product.name
        let resolvedGroups = line.product.variantGroups.map { store.resolvedGroup(for: $0) }
        let chosenOptions: [ProductVariantOption] = resolvedGroups.compactMap { group in
            guard let optionID = selectedVariants[line.product.id]?[group.id] else { return nil }
            return group.options.first { $0.id == optionID }
        }
        if !chosenOptions.isEmpty {
            name += " (\(chosenOptions.map { $0.name }.joined(separator: ", ")))"
        }
        let note = (notes[line.product.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            name += " — \(note)"
        }
        let unitPrice = line.product.price + chosenOptions.reduce(0) { $0 + $1.priceDelta }
        // Elke gekozen optie ook los met haar eigen (meer)prijs bewaren, zodat
        // je in de Aanvraag kunt zien wat zo'n optie/"subproduct" kost — de
        // meerprijs schaalt mee met het aantal, net als de rest van de regel.
        let optionBreakdown = chosenOptions.map { option in
            QuoteItemOption(name: option.name, price: option.priceDelta * Double(line.quantity))
        }
        return QuoteItem(name: name, price: unitPrice * Double(line.quantity), optionBreakdown: optionBreakdown)
    }

    private var selectedItems: [QuoteItem] { selectedLines.map(quoteItem(for:)) }

    private var selectedTotal: Double {
        selectedItems.reduce(0) { $0 + $1.price }
    }

    private func addSelectedToRequest() {
        guard !selectedItems.isEmpty else { return }
        requestStore.add(category: "Producten", items: selectedItems, total: selectedTotal)
        quantities = [:]
        notes = [:]
        selectedVariants = [:]
    }

    var body: some View {
        Group {
            #if os(macOS)
            macLayout
            #else
            mobileLayout
            #endif
        }
        .withKeyboardDismiss()
        .sheet(isPresented: $showSettingsSheet) {
            settingsSheet
        }
        .sheet(item: $editingProduct) { product in
            productEditSheet(product: product)
        }
        .sheet(isPresented: $showSubmenuConfigurator) {
            submenuConfiguratorSheet
        }
        .alert("Opslagfout", isPresented: Binding(
            get: { store.lastError != nil },
            set: { isPresented in if !isPresented { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "Onbekende fout")
        }
        .alert("Nieuwe categorie", isPresented: $showNewCategoryPrompt) {
            TextField("Naam van de categorie", text: $newCategoryInput)
            Button("Toevoegen") {
                let trimmed = newCategoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    newCategoryTarget?.wrappedValue = trimmed
                }
                newCategoryInput = ""
                newCategoryTarget = nil
            }
            Button("Annuleer", role: .cancel) {
                newCategoryInput = ""
                newCategoryTarget = nil
            }
        } message: {
            Text("Deze naam wordt gebruikt zodra je het product opslaat.")
        }
        .confirmationDialog(
            "Product verwijderen",
            isPresented: Binding(
                get: { productPendingDeletion != nil },
                set: { isPresented in if !isPresented { productPendingDeletion = nil } }
            ),
            presenting: productPendingDeletion
        ) { product in
            Button("Verwijder \"\(product.name)\"", role: .destructive) {
                store.delete(id: product.id)
                quantities[product.id] = nil
                notes[product.id] = nil
                selectedVariants[product.id] = nil
                productPendingDeletion = nil
            }
            Button("Annuleer", role: .cancel) { productPendingDeletion = nil }
        } message: { product in
            Text("Weet je zeker dat je \"\(product.name)\" wilt verwijderen? Dit kan niet ongedaan worden gemaakt.")
        }
    }

    /// Dropdown met bestaande categorieën (plus een "+"-knop om een nieuwe,
    /// nog niet bestaande categorie te typen) — gebruikt bij zowel "Nieuw
    /// product" als het bewerken van een bestaand product.
    @ViewBuilder
    private func categoryPicker(selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Menu {
                if store.categories.isEmpty {
                    Text("Nog geen categorieën")
                } else {
                    ForEach(store.categories, id: \.self) { category in
                        Button {
                            selection.wrappedValue = category
                        } label: {
                            if selection.wrappedValue == category {
                                Label(category, systemImage: "checkmark")
                            } else {
                                Text(category)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.isEmpty ? "Categorie" : selection.wrappedValue)
                        .foregroundStyle(selection.wrappedValue.isEmpty ? .secondary : .primary)
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
                newCategoryTarget = selection
                newCategoryInput = ""
                showNewCategoryPrompt = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Nieuwe categorie toevoegen")
        }
    }

    /// Volledig bewerkformulier voor een bestaand product (naam, categorie,
    /// omschrijving, submenu's en prijs) — als sheet, zodat er ruimte is voor
    /// de langere omschrijving en meerdere submenu-groepen.
    private func productEditSheet(product: ProductItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Product bewerken").font(.title3.bold())

                TextField("Naam", text: $editName)
                    .textFieldStyle(.roundedBorder)

                categoryPicker(selection: $editCategory)

                TextField("Omschrijving (optioneel)", text: $editDescription, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Submenu's (bijv. Kleur, Maat)").font(.subheadline.weight(.semibold))
                    variantGroupsEditor(groups: $editVariantGroups)
                }

                HStack(spacing: 8) {
                    AppNumberField(placeholder: "0,00", value: $editPrice)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("€")
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button("Annuleer") { editingProduct = nil }
                    Button("Opslaan") {
                        store.update(
                            id: product.id,
                            name: editName,
                            category: editCategory,
                            description: editDescription,
                            variantGroups: editVariantGroups,
                            price: editPrice
                        )
                        editingProduct = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 420)
        .withKeyboardDismiss()
    }

    /// Bewerker voor de submenu-groepen van een product: elke rij is één
    /// groep (naam + kommagescheiden opties, bijv. "Kleur" met "Rood, Zwart,
    /// Blauw"), met een knop om er nog een groep bij te zetten. Wordt zowel
    /// bij "Nieuw product" als bij het bewerken van een bestaand product
    /// gebruikt, zodat een product meerdere onafhankelijke submenu's kan
    /// hebben.
    @ViewBuilder
    private func variantGroupsEditor(groups: Binding<[ProductVariantGroup]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { $group in
                if let sharedID = group.sharedGroupID {
                    let resolved = store.resolvedGroup(for: group)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(resolved.name)
                                    .font(.subheadline.weight(.semibold))
                            }
                            Spacer()
                            Button("Ontkoppel") {
                                group.name = resolved.name
                                group.options = resolved.options
                                group.sharedGroupID = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            Button(role: .destructive) {
                                groups.wrappedValue.removeAll { $0.id == group.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(resolved.options.map { option in
                            option.priceDelta == 0 ? option.name : "\(option.name) (+\(formattedPrice(option.priceDelta)))"
                        }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .id(sharedID)
                } else {
                    HStack(spacing: 8) {
                        TextField("Naam, bijv. Kleur", text: $group.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        TextField(
                            "Opties, evt. met meerprijs, bijv. Rood, Zwart:5",
                            text: Binding(
                                get: { ProductStore.formatVariantOptions(group.options) },
                                set: { group.options = ProductStore.parseVariantOptions($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        if !store.sharedVariantGroups.isEmpty {
                            Menu {
                                ForEach(store.sharedVariantGroups) { shared in
                                    Button(shared.name) {
                                        group.sharedGroupID = shared.id
                                    }
                                }
                            } label: {
                                Image(systemName: "link.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Koppel aan gedeeld submenu uit de configurator")
                        }
                        Button(role: .destructive) {
                            groups.wrappedValue.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                groups.wrappedValue.append(ProductVariantGroup(name: "", options: []))
            } label: {
                Label("Submenu toevoegen", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// Eén submenu-knop voor één groep van een product (bijv. "Kleur") — de
    /// gekozen optie wordt bij het toevoegen aan de aanvraag achter de
    /// productnaam gezet, en de meerprijs (indien aanwezig) telt mee in de
    /// prijs. Een product met meerdere groepen krijgt meerdere van deze
    /// knoppen naast elkaar. Is de groep gekoppeld aan een gedeelde
    /// configurator-groep, dan gebruiken we hier altijd de actuele naam/opties
    /// (zie `ProductStore.resolvedGroup`).
    @ViewBuilder
    private func variantGroupMenu(product: ProductItem, group rawGroup: ProductVariantGroup) -> some View {
        let group = store.resolvedGroup(for: rawGroup)
        Menu {
            ForEach(group.options) { option in
                Button {
                    selectedVariants[product.id, default: [:]][group.id] = option.id
                } label: {
                    let label = option.priceDelta == 0 ? option.name : "\(option.name) (+\(formattedPrice(option.priceDelta)))"
                    if selectedVariants[product.id]?[group.id] == option.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedOptionLabel(product: product, group: group))
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Kies \(group.name)")
    }

    private func selectedOptionLabel(product: ProductItem, group: ProductVariantGroup) -> String {
        guard let selectedID = selectedVariants[product.id]?[group.id],
              let option = group.options.first(where: { $0.id == selectedID }) else {
            return group.name
        }
        return option.name
    }

    private func formattedPrice(_ value: Double) -> String {
        value.formatted(currency)
    }

    // MARK: - Lay-outs

    #if os(macOS)
    /// Compacte twee-koloms lay-out voor de Mac: links de productenlijst met
    /// categoriefilter, rechts een vaste zijbalk met "Nieuw product" en de
    /// winkelwagen ("Geselecteerd"), zodat je die niet hoeft weg te scrollen.
    private var macLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            syncStatusRow
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if groupedProducts.count > 1 {
                        categoryFilterBar
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            productListContent
                        }
                        .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    addProductCard
                    selectionSummaryCard
                }
                .frame(width: 460, alignment: .top)
            }
        }
        .padding(18)
    }
    #endif

    private var mobileLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                syncStatusRow
                addProductCard

                if !selectedItems.isEmpty {
                    selectionSummaryCard
                }

                if groupedProducts.count > 1 {
                    categoryFilterBar
                }

                productListContent
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var productListContent: some View {
        if store.products.isEmpty {
            ContentUnavailableView(
                "Nog geen producten",
                systemImage: "shippingbox",
                description: Text("Voeg hierboven een product toe, of importeer een CSV-bestand.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if filteredGroupedProducts.isEmpty {
            ContentUnavailableView(
                "Geen producten in deze categorie",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Kies hierboven een andere categorie, of \"Alle\".")
            )
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ForEach(filteredGroupedProducts, id: \.category) { group in
                categorySection(group.category, group.items)
            }
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
                Text("Producten").font(.title2.bold())
                Text("Beheer losse producten die je verkoopt (folie, striping, schoonmaakmiddelen, enz.) en voeg ze direct toe aan een aanvraag.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Importeren en exporteren")
        }
    }

    /// Synchronisatiestatus + handmatige "Synchroniseer nu"-knop, in dezelfde
    /// stijl als bij Prijslijst en Projecten — nieuwe producten worden ook
    /// automatisch gesynchroniseerd zodra je ze toevoegt/wijzigt, maar het
    /// andere apparaat ziet dat pas vanzelf bij het (opnieuw) openen van de
    /// app. Met deze knop kun je dat ook meteen forceren, zonder de app
    /// opnieuw te hoeven starten.
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

    /// Inhoud van het instellingen-sheet (tandwiel-knop): import/export, uit
    /// het zicht van de gewone productenlijst om die rustiger te houden.
    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Instellingen").font(.title3.bold())
                Spacer()
                Button("Klaar") { showSettingsSheet = false }
            }
            importExportCard
            submenuConfiguratorCard
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 320)
        .withKeyboardDismiss()
    }

    private var submenuConfiguratorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showSettingsSheet = false
                showSubmenuConfigurator = true
            } label: {
                Label("Submenu configurator", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            Text("Beheer herbruikbare submenu's (bijv. Kleur) met een prijs per optie, die je aan meerdere producten tegelijk kunt koppelen. Verander je hier de prijs, dan werkt dat meteen door bij alle gekoppelde producten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Beheerscherm voor gedeelde submenu-groepen: een lijst met bestaande
    /// groepen (elk met bewerk/verwijder-knop) plus een formulier om een
    /// nieuwe groep toe te voegen of de geselecteerde te bewerken.
    private var submenuConfiguratorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Submenu configurator").font(.title3.bold())
                Spacer()
                Button("Klaar") { showSubmenuConfigurator = false }
            }
            Text("Herbruikbare submenu's die je aan meerdere producten kunt koppelen via het link-icoontje bij een product. Wijzig je hier een naam, optie of prijs, dan werkt dat meteen door bij alle gekoppelde producten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.sharedVariantGroups.isEmpty {
                        Text("Nog geen gedeelde submenu's.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.sharedVariantGroups) { shared in
                            sharedGroupRow(shared)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(editingSharedGroup == nil ? "Nieuwe submenu-groep" : "Submenu-groep bewerken")
                    .font(.subheadline.weight(.semibold))
                TextField("Naam, bijv. Kleur", text: $sharedGroupDraftName)
                    .textFieldStyle(.roundedBorder)
                sharedOptionsEditor(options: $sharedGroupDraftOptions)
                HStack {
                    if editingSharedGroup != nil {
                        Button("Annuleer") {
                            resetSharedGroupDraft()
                        }
                    }
                    Spacer()
                    Button(editingSharedGroup == nil ? "Toevoegen" : "Opslaan") {
                        if let editing = editingSharedGroup {
                            store.updateSharedVariantGroup(id: editing.id, name: sharedGroupDraftName, options: sharedGroupDraftOptions)
                        } else {
                            store.addSharedVariantGroup(name: sharedGroupDraftName, options: sharedGroupDraftOptions)
                        }
                        resetSharedGroupDraft()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sharedGroupDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 500)
        .withKeyboardDismiss()
    }

    private func resetSharedGroupDraft() {
        editingSharedGroup = nil
        sharedGroupDraftName = ""
        sharedGroupDraftOptions = []
    }

    @ViewBuilder
    private func sharedGroupRow(_ shared: SharedVariantGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shared.name).font(.subheadline.weight(.semibold))
                Text(shared.options.map { option in
                    option.priceDelta == 0 ? option.name : "\(option.name) (+\(formattedPrice(option.priceDelta)))"
                }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editingSharedGroup = shared
                sharedGroupDraftName = shared.name
                sharedGroupDraftOptions = shared.options
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                store.deleteSharedVariantGroup(id: shared.id)
                if editingSharedGroup?.id == shared.id {
                    resetSharedGroupDraft()
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Bewerker voor de opties van één gedeelde submenu-groep: elke rij is
    /// één optie (naam + meerprijs als apart getalveld) met een eigen, stabiele
    /// identiteit — zodat een prijswijziging de koppeling met al gekozen
    /// opties in een lopende (nog niet verzonden) selectie niet per ongeluk
    /// verbreekt, wat bij een kommagescheiden tekstveld wel zou kunnen gebeuren.
    @ViewBuilder
    private func sharedOptionsEditor(options: Binding<[ProductVariantOption]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { $option in
                HStack(spacing: 8) {
                    TextField("Optie, bijv. Rood", text: $option.name)
                        .textFieldStyle(.roundedBorder)
                    AppNumberField(placeholder: "0,00", value: $option.priceDelta)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("€")
                    Button(role: .destructive) {
                        options.wrappedValue.removeAll { $0.id == option.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                options.wrappedValue.append(ProductVariantOption(name: "", priceDelta: 0))
            } label: {
                Label("Optie toevoegen", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var importExportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    exportDocument = PriceListCSVDocument(csv: store.data.toCSV())
                    showExporter = true
                } label: {
                    Label("Exporteer producten", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    showImporter = true
                } label: {
                    Label("Importeer producten", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            Text("Exporteer als CSV-bestand — te openen en bewerken in Excel of Numbers — en importeer het later weer terug. Handig als back-up, of om een lijst uit Moneybird over te nemen (kolommen: Naam, Categorie, Omschrijving, Varianten, Prijs — een oudere lijst met alleen Naam, Categorie, Prijs werkt ook).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "TintKing-producten"
        ) { result in
            if case .failure(let error) = result {
                importErrorMessage = "Kon het bestand niet opslaan: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    if let parsed = ProductData.fromCSV(text) {
                        pendingImport = parsed
                        showImportConfirm = true
                    } else {
                        importErrorMessage = "Kon het bestand niet herkennen. Controleer of dit een geëxporteerde producten-CSV is."
                    }
                } catch {
                    importErrorMessage = "Kon het bestand niet openen: \(error.localizedDescription)"
                }
            case .failure(let error):
                importErrorMessage = "Kon het bestand niet openen: \(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "Producten importeren",
            isPresented: $showImportConfirm,
            presenting: pendingImport
        ) { imported in
            Button("Vervang huidige producten", role: .destructive) {
                store.replaceAll(with: imported)
                importSuccessMessage = "Producten geïmporteerd (\(imported.importSummary))."
                pendingImport = nil
            }
            Button("Voeg toe aan bestaande producten") {
                store.appendImported(imported)
                importSuccessMessage = "\(imported.importSummary) toegevoegd."
                pendingImport = nil
            }
            Button("Annuleer", role: .cancel) { pendingImport = nil }
        } message: { imported in
            Text("Dit bestand bevat \(imported.importSummary). Wil je je huidige productenlijst vervangen, of de geïmporteerde producten toevoegen aan je bestaande lijst?")
        }
        .alert("Importfout", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { isPresented in if !isPresented { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "Onbekende fout")
        }
        .alert("Geïmporteerd", isPresented: Binding(
            get: { importSuccessMessage != nil },
            set: { isPresented in if !isPresented { importSuccessMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importSuccessMessage = nil }
        } message: {
            Text(importSuccessMessage ?? "")
        }
    }

    /// Horizontale rij met categorie-knoppen zodat je snel kunt filteren op
    /// bijvoorbeeld alleen "Folie" of alleen "Striping", i.p.v. steeds de
    /// hele lijst te doorzoeken.
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryFilterChip(title: "Alle", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(groupedProducts, id: \.category) { group in
                    categoryFilterChip(title: "\(group.category) (\(group.items.count))", isSelected: selectedCategory == group.category) {
                        selectedCategory = selectedCategory == group.category ? nil : group.category
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryFilterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12))
                )
                .foregroundStyle(isSelected ? .white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func resetNewProductFields() {
        newName = ""
        newCategory = ""
        newDescription = ""
        newVariantGroups = []
        newPrice = 0
    }

    /// Optionele extra velden bij "Nieuw product": omschrijving (zoals in
    /// Moneybird) en varianten (bijv. kleuren) — ingeklapt, zodat het gewone
    /// snel-toevoegen niet in de weg zit.
    private var newProductExtraFields: some View {
        DisclosureGroup("Meer (omschrijving, varianten)") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Omschrijving (optioneel)", text: $newDescription, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Text("Submenu's (optioneel), bijv. Kleur met opties Rood, Zwart, Blauw")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                variantGroupsEditor(groups: $newVariantGroups)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private var addProductCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nieuw product").font(.headline)
            #if os(macOS)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Naam, bijv. Lampenfolie geel", text: $newName)
                    .textFieldStyle(.roundedBorder)
                categoryPicker(selection: $newCategory)
                HStack(spacing: 8) {
                    AppNumberField(placeholder: "0,00", value: $newPrice)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("€")
                    Spacer()
                    Button {
                        store.add(name: newName, category: newCategory, description: newDescription, variantGroups: newVariantGroups, price: newPrice)
                        resetNewProductFields()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                newProductExtraFields
            }
            #else
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Naam, bijv. Lampenfolie geel", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    categoryPicker(selection: $newCategory)
                        .frame(maxWidth: 160)
                    AppNumberField(placeholder: "0,00", value: $newPrice)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("€")
                    Button {
                        store.add(name: newName, category: newCategory, description: newDescription, variantGroups: newVariantGroups, price: newPrice)
                        resetNewProductFields()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                newProductExtraFields
            }
            #endif
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var selectionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Geselecteerd").font(.headline)
            if selectedItems.isEmpty {
                Text("Nog niets geselecteerd — zet bij een product een aantal om het hier te zien.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Notitie wordt hier bewust niet meer los ingevoerd — die
                // pas je toch pas aan zodra het in de Aanvraag staat (via het
                // potlood-icoontje daar). Bij het toevoegen aan de aanvraag
                // gaat een eventuele productomschrijving nog wel automatisch
                // mee als notitie, net als voorheen.
                ForEach(selectedLines) { line in
                    HStack(alignment: .top) {
                        Text(line.quantity > 1 ? "\(line.product.name) ×\(line.quantity)" : line.product.name)
                        Spacer()
                        Text(line.product.price * Double(line.quantity), format: currency)
                    }
                    .font(.subheadline)
                    .padding(.bottom, 2)
                }
                Divider()
                HStack {
                    Text("Totaal").fontWeight(.semibold)
                    Spacer()
                    Text(selectedTotal, format: currency).fontWeight(.semibold)
                }
                Button {
                    addSelectedToRequest()
                } label: {
                    Label("Toevoegen aan aanvraag", systemImage: "cart.badge.plus")
                }
                .disabled(selectedTotal <= 0)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func categorySection(_ category: String, _ items: [ProductItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category).font(.headline)
            ForEach(items) { product in
                productRow(product)
                if product.id != items.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Aantal instellen — via de "+"/"−"-knoppen voor een enkel stapje, of
    /// door rechtstreeks een getal in te typen in het veld (handig om in één
    /// keer een groot aantal toe te voegen, i.p.v. tientallen keren op "+" te
    /// tikken). Zet het aantal bij 0 of minder weer helemaal uit, en vult bij
    /// de eerste keer selecteren automatisch de productomschrijving als
    /// notitie in, net als voorheen.
    private func setQuantity(for product: ProductItem, to newValue: Int) {
        let wasUnselected = (quantities[product.id] ?? 0) == 0
        if newValue <= 0 {
            quantities[product.id] = nil
        } else {
            quantities[product.id] = newValue
            if wasUnselected, (notes[product.id] ?? "").isEmpty, !product.description.isEmpty {
                notes[product.id] = product.description
            }
        }
    }

    /// Aantal-selector per product: een intypbaar aantal-veld (voor in één
    /// keer een groot aantal toevoegen) plus een "+"-knop, met een
    /// "−"-knop die alleen verschijnt zodra er iets is geselecteerd.
    @ViewBuilder
    private func quantityControl(for product: ProductItem) -> some View {
        let qty = quantities[product.id] ?? 0
        HStack(spacing: 6) {
            if qty > 0 {
                Button {
                    setQuantity(for: product, to: qty - 1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }

            AppNumberField(
                placeholder: "0",
                value: Binding(
                    get: { Double(qty) },
                    set: { setQuantity(for: product, to: Int($0.rounded())) }
                ),
                decimals: 0...0
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 34)

            Button {
                setQuantity(for: product, to: qty + 1)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .frame(minWidth: 92, alignment: .trailing)
    }

    @ViewBuilder
    private func productRow(_ product: ProductItem) -> some View {
        HStack(spacing: 8) {
            quantityControl(for: product)

            Button {
                editingProduct = product
                editName = product.name
                editCategory = product.category
                editDescription = product.description
                editVariantGroups = product.variantGroups
                editPrice = product.price
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                productPendingDeletion = product
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(product.name)
                    Text(product.price, format: currency)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                if !product.description.isEmpty {
                    Text(product.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !product.variantGroups.isEmpty {
                HStack(spacing: 4) {
                    ForEach(product.variantGroups) { group in
                        variantGroupMenu(product: product, group: group)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
