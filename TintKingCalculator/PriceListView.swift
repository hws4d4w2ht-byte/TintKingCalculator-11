import SwiftUI

enum PriceCategoryStyle {
    case none
    case picker([String])
    case freeText
}

struct PriceListView: View {
    @ObservedObject var store: PriceListStore

    @State private var showExporter = false
    @State private var exportDocument = PriceListCSVDocument(csv: "")
    @State private var showImporter = false
    @State private var pendingImport: PriceListData?
    @State private var showImportConfirm = false
    @State private var importErrorMessage: String?
    @State private var importSuccessMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PriceListHeader(
                    title: "Prijslijst",
                    subtitle: "Beheer hier de standaardprijzen die de calculators gebruiken. Wijzigingen gelden meteen voor nieuwe berekeningen."
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button {
                            exportDocument = PriceListCSVDocument(csv: store.data.toCSV())
                            showExporter = true
                        } label: {
                            Label("Exporteer back-up", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showImporter = true
                        } label: {
                            Label("Importeer back-up", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Exporteer als CSV-bestand — te openen en bewerken in Excel of Numbers — en importeer het later weer terug. Handig als back-up, bijvoorbeeld als je alle prijzen door een crash kwijt bent.")
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
                    defaultFilename: "TintKing-prijslijst"
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
                            if let parsed = PriceListData.fromCSV(text) {
                                pendingImport = parsed
                                showImportConfirm = true
                            } else {
                                importErrorMessage = "Kon het bestand niet herkennen. Controleer of dit een geëxporteerde prijslijst-CSV is."
                            }
                        } catch {
                            importErrorMessage = "Kon het bestand niet openen: \(error.localizedDescription)"
                        }
                    case .failure(let error):
                        importErrorMessage = "Kon het bestand niet openen: \(error.localizedDescription)"
                    }
                }
                .confirmationDialog(
                    "Prijslijst vervangen?",
                    isPresented: $showImportConfirm,
                    presenting: pendingImport
                ) { imported in
                    Button("Vervang huidige prijslijst", role: .destructive) {
                        store.replaceAll(with: imported)
                        importSuccessMessage = "Prijslijst geïmporteerd (\(imported.importSummary))."
                        pendingImport = nil
                    }
                    Button("Annuleer", role: .cancel) { pendingImport = nil }
                } message: { imported in
                    Text("Dit bestand bevat \(imported.importSummary). Dit vervangt je hele huidige prijslijst — dat kan niet ongedaan worden gemaakt.")
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

                PriceListSection(
                    title: "Tint – basispakketten",
                    entries: store.data.tintBasePackages,
                    categoryStyle: .picker(["Los samenstellen", "B-Stijl", "A-Stijl", "Merkspecifiek"]),
                    protectedNames: ["Geen basispakket"],
                    onUpdate: { name, price, category in store.updateTintBasePackage(name: name, price: price, category: category) },
                    onDelete: { name in store.deleteTintBasePackage(name: name) },
                    onAdd: { name, price, category in store.addTintBasePackage(name: name, price: price, category: category) },
                    onReset: { store.resetTintBasePackagesToDefault() }
                )

                PriceListSection(
                    title: "Tint – extra's / losse ruiten",
                    entries: store.data.tintExtras,
                    categoryStyle: .picker(["Losse ruit", "Werkbus"]),
                    protectedNames: [],
                    onUpdate: { name, price, category in store.updateTintExtra(name: name, price: price, category: category) },
                    onDelete: { name in store.deleteTintExtra(name: name) },
                    onAdd: { name, price, category in store.addTintExtra(name: name, price: price, category: category) },
                    onReset: { store.resetTintExtrasToDefault() }
                )

                PriceListSection(
                    title: "Ontchromen – onderdelen",
                    entries: store.data.dechromeParts,
                    categoryStyle: .none,
                    protectedNames: [],
                    onUpdate: { name, price, _ in store.updateDechromePart(name: name, price: price) },
                    onDelete: { name in store.deleteDechromePart(name: name) },
                    onAdd: { name, price, _ in store.addDechromePart(name: name, price: price) },
                    onReset: { store.resetDechromePartsToDefault() }
                )

                PriceListSection(
                    title: "Snijfolie – materialen (prijs per m²)",
                    entries: store.data.cutFoilMaterials ?? [],
                    categoryStyle: .none,
                    protectedNames: [],
                    onUpdate: { name, price, _ in store.updateCutFoilMaterial(name: name, price: price) },
                    onDelete: { name in store.deleteCutFoilMaterial(name: name) },
                    onAdd: { name, price, _ in store.addCutFoilMaterial(name: name, price: price) },
                    onReset: { store.resetCutFoilMaterialsToDefault() }
                )
            }
            .padding(24)
        }
        .alert("Opslagfout", isPresented: Binding(
            get: { store.lastError != nil },
            set: { isPresented in if !isPresented { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "Onbekende fout")
        }
    }
}

private struct PriceListHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: "list.bullet.rectangle")
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

private struct PriceListSection: View {
    let title: String
    let entries: [PriceListEntry]
    let categoryStyle: PriceCategoryStyle
    let protectedNames: [String]

    let onUpdate: (String, Double, String) -> Void
    let onDelete: (String) -> Void
    let onAdd: (String, Double, String) -> Void
    let onReset: () -> Void

    @State private var editedPrices: [String: Double] = [:]
    @State private var editedCategories: [String: String] = [:]
    @State private var newName = ""
    @State private var newPrice: Double = 0
    @State private var newCategory: String = ""
    @State private var showResetConfirm = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }

    private func price(for entry: PriceListEntry) -> Double {
        editedPrices[entry.name] ?? entry.price
    }

    private func category(for entry: PriceListEntry) -> String {
        editedCategories[entry.name] ?? entry.category
    }

    private var sortedEntries: [PriceListEntry] {
        entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        GroupBox(title) {
            VStack(spacing: 0) {
                ForEach(sortedEntries) { entry in
                    if isCompact {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.name)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 12) {
                                categoryField(for: entry)

                                Spacer(minLength: 8)

                                AppNumberField(
                                    placeholder: "Prijs",
                                    value: Binding(
                                        get: { price(for: entry) },
                                        set: { newValue in
                                            editedPrices[entry.name] = newValue
                                            onUpdate(entry.name, newValue, category(for: entry))
                                        }
                                    )
                                )
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .disabled(protectedNames.contains(entry.name))
                                Text("€").foregroundStyle(.secondary)

                                Button(role: .destructive) {
                                    onDelete(entry.name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(protectedNames.contains(entry.name))
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 12) {
                            Text(entry.name)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            categoryField(for: entry)

                            AppNumberField(
                                placeholder: "Prijs",
                                value: Binding(
                                    get: { price(for: entry) },
                                    set: { newValue in
                                        editedPrices[entry.name] = newValue
                                        onUpdate(entry.name, newValue, category(for: entry))
                                    }
                                )
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .disabled(protectedNames.contains(entry.name))
                            Text("€").foregroundStyle(.secondary)

                            Button(role: .destructive) {
                                onDelete(entry.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(protectedNames.contains(entry.name))
                        }
                        .padding(.vertical, 6)
                    }
                    Divider()
                }

                if isCompact {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nieuwe naam", text: $newName)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 12) {
                            newCategoryField

                            Spacer(minLength: 8)

                            AppNumberField(placeholder: "Prijs", value: $newPrice)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("€").foregroundStyle(.secondary)
                        }

                        Button {
                            onAdd(newName, newPrice, newCategory)
                            newName = ""
                            newPrice = 0
                        } label: {
                            Label("Toevoegen", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 10)
                } else {
                    HStack(spacing: 12) {
                        TextField("Nieuwe naam", text: $newName)
                            .textFieldStyle(.roundedBorder)

                        newCategoryField

                        AppNumberField(placeholder: "Prijs", value: $newPrice)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("€").foregroundStyle(.secondary)

                        Button {
                            onAdd(newName, newPrice, newCategory)
                            newName = ""
                            newPrice = 0
                        } label: {
                            Label("Toevoegen", systemImage: "plus")
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 10)
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Herstel standaardprijzen", systemImage: "arrow.counterclockwise")
                    }
                }
                .padding(.top, 6)
            }
            .padding(8)
        }
        .confirmationDialog(
            "Weet je zeker dat je deze prijzen wilt terugzetten naar de standaardwaarden?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Herstel standaardprijzen", role: .destructive) {
                editedPrices.removeAll()
                editedCategories.removeAll()
                onReset()
            }
            Button("Annuleer", role: .cancel) {}
        }
        .onAppear {
            if case .picker(let options) = categoryStyle, newCategory.isEmpty {
                newCategory = options.first ?? ""
            }
        }
    }

    @ViewBuilder
    private func categoryField(for entry: PriceListEntry) -> some View {
        switch categoryStyle {
        case .none:
            EmptyView()
        case .picker(let options):
            Picker("", selection: Binding(
                get: { category(for: entry) },
                set: { newValue in
                    editedCategories[entry.name] = newValue
                    onUpdate(entry.name, price(for: entry), newValue)
                }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(protectedNames.contains(entry.name))
        case .freeText:
            TextField(
                "Categorie",
                text: Binding(
                    get: { category(for: entry) },
                    set: { newValue in
                        editedCategories[entry.name] = newValue
                        onUpdate(entry.name, price(for: entry), newValue)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .disabled(protectedNames.contains(entry.name))
        }
    }

    @ViewBuilder
    private var newCategoryField: some View {
        switch categoryStyle {
        case .none:
            EmptyView()
        case .picker(let options):
            Picker("", selection: $newCategory) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
        case .freeText:
            TextField("Categorie", text: $newCategory)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }
}
