import SwiftUI
import PhotosUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Klantgegevens: per klant een doorzoekbaar overzicht van gebruikte folie/materiaal,
/// ter vervanging van het kladblok. Gedeeld tussen Mac en mobiel. Een
/// NavigationSplitView: links een sidebar om een klant te selecteren, rechts
/// alle gegevens van de geselecteerde klant — dit scherm is zelf al de
/// navigatiecontainer (dus niet nogmaals in een NavigationStack wrappen).
struct CustomerView: View {
    @ObservedObject var store: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @Binding var selectedCustomerID: UUID?

    @State private var searchText = ""
    @State private var showDuplicateConfirm = false
    @State private var duplicateMergeMessage: String?

    private var filteredCustomers: [Customer] {
        let all = store.sortedCustomers
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { customer in
            if customer.name.lowercased().contains(query) { return true }
            if customer.generalNote.lowercased().contains(query) { return true }
            return customer.foilLines.contains {
                $0.displayText.lowercased().contains(query) || $0.note.lowercased().contains(query)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCustomerID) {
                if filteredCustomers.isEmpty {
                    Text(store.customers.isEmpty
                         ? "Nog geen klanten. Tik op + om te beginnen."
                         : "Geen klanten gevonden voor \u{201c}\(searchText)\u{201d}.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filteredCustomers) { customer in
                        CustomerRow(customer: customer)
                            .tag(customer.id)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.delete(filteredCustomers[index]) }
                    }
                }
            }
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, 36)
            .listSectionSpacing(.compact)
            #endif
            .withKeyboardDismiss()
            .navigationTitle("Klanten")
            .searchable(text: $searchText, prompt: "Zoek op klant, merk of type")
            .toolbar {
                if !store.duplicateGroups.isEmpty {
                    ToolbarItem {
                        Button {
                            showDuplicateConfirm = true
                        } label: {
                            Label("\(store.duplicateGroups.count) duplicaat\(store.duplicateGroups.count == 1 ? "" : "en")", systemImage: "exclamationmark.triangle")
                        }
                        .help("Waarschijnlijk door het synchroniseren staan sommige klanten dubbel — tik om samen te voegen.")
                    }
                }
                ToolbarItem {
                    Button {
                        let new = store.addCustomer(name: "")
                        selectedCustomerID = new.id
                        ActivityLogStore.shared.log("Nieuwe klant aangemaakt", systemImage: "person.badge.plus", tab: .klanten, customerID: new.id)
                    } label: {
                        Label("Nieuwe klant", systemImage: "plus")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
            .confirmationDialog(
                "Duplicaten samenvoegen",
                isPresented: $showDuplicateConfirm
            ) {
                Button("Samenvoegen") {
                    let count = store.mergeDuplicates()
                    duplicateMergeMessage = "\(count) duplicaat\(count == 1 ? "" : "en") samengevoegd. Alle folie/materiaal-regels en notities zijn bewaard."
                }
                Button("Annuleer", role: .cancel) {}
            } message: {
                Text("Er \(store.duplicateGroups.count == 1 ? "is 1 klantnaam" : "zijn \(store.duplicateGroups.count) klantnamen") die meerdere keren voorkomen, waarschijnlijk doordat je Mac en telefoon ooit los van elkaar dezelfde beginlijst kregen. Per naam wordt alle informatie samengevoegd tot één klant; de overbodige duplicaten worden daarna verwijderd (ook uit de cloud). Dit kan niet ongedaan worden gemaakt.")
            }
            .alert("Klaar", isPresented: Binding(
                get: { duplicateMergeMessage != nil },
                set: { isPresented in if !isPresented { duplicateMergeMessage = nil } }
            )) {
                Button("OK", role: .cancel) { duplicateMergeMessage = nil }
            } message: {
                Text(duplicateMergeMessage ?? "")
            }
        } detail: {
            if let selectedCustomerID {
                CustomerDetailView(store: store, moneybirdSettings: moneybirdSettings, customerID: selectedCustomerID, selection: $selectedCustomerID)
                    .id(selectedCustomerID)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Selecteer een klant")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        #endif
    }
}

private struct CustomerRow: View {
    let customer: Customer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(customer.name.isEmpty ? "Naamloos" : customer.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            if let last = customer.foilLines.last {
                Text(last.displayText.isEmpty ? "Nieuwe regel" : last.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if customer.foilLines.count > 1 {
                Text("+\(customer.foilLines.count - 1) andere regel\(customer.foilLines.count - 1 == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private enum CustomerDetailTab: String, CaseIterable, Hashable {
    case folie = "Folie / materiaal"
    case notities = "Notities & foto's"
}

private struct CustomerDetailView: View {
    @ObservedObject var store: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    let customerID: UUID
    @Binding var selection: UUID?

    @State private var name: String = ""
    @State private var phone: String = ""
    @State private var generalNote: String = ""
    @State private var editingLine: CustomerFoilLine?
    @State private var isAddingLine = false
    @State private var confirmDelete = false
    @State private var showMoneybirdPicker = false
    @State private var editingNote: CustomerNote?
    @State private var isAddingNote = false
    @State private var selectedTab: CustomerDetailTab = .folie

    private var customer: Customer? {
        store.customers.first { $0.id == customerID }
    }

    var body: some View {
        Form {
            Section {
                TextField("Naam", text: $name)
                    .font(.title3.weight(.semibold))
                TextField("Telefoonnummer (voor WhatsApp)", text: $phone)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
            } header: {
                Label("Klant", systemImage: "person.crop.circle")
            }

            Section {
                if let contact = customer?.moneybirdContact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .font(.body.weight(.medium))
                        if !contact.address.isEmpty {
                            Text(contact.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !contact.email.isEmpty {
                            Text(contact.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !contact.phone.isEmpty {
                            Text(contact.phone)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showMoneybirdPicker = true
                    } label: {
                        Label("Andere klant koppelen", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button("Ontkoppelen", role: .destructive) {
                        unlinkMoneybird()
                    }
                } else {
                    Text("Nog niet gekoppeld aan een Moneybird-klant.")
                        .foregroundStyle(.secondary)
                    Button {
                        showMoneybirdPicker = true
                    } label: {
                        Label("Koppel aan Moneybird-klant", systemImage: "link")
                    }
                }
            } header: {
                Label("Moneybird", systemImage: "link.circle")
            }

            Section {
                Picker("Onderdeel", selection: $selectedTab) {
                    ForEach(CustomerDetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if selectedTab == .folie {
                Section {
                    let lines = customer?.foilLines ?? []
                    if lines.isEmpty {
                        Text("Nog geen folie toegevoegd voor deze klant.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lines) { line in
                            HStack {
                                Button {
                                    editingLine = line
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.displayText.isEmpty ? "Nieuwe regel" : line.displayText)
                                            .foregroundStyle(.primary)
                                        if !line.note.trimmingCharacters(in: .whitespaces).isEmpty {
                                            Text(line.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button {
                                    deleteLine(line)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        }
                    }

                    Button {
                        isAddingLine = true
                    } label: {
                        Label("Regel toevoegen", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Label("Folie / materiaal", systemImage: "square.stack.3d.up")
                }
            }

            if selectedTab == .notities {
                Section {
                    TextEditor(text: $generalNote)
                        .frame(minHeight: 70, maxHeight: 140)
                } header: {
                    Label("Notitie", systemImage: "note.text")
                }

                Section {
                    let projectNotes = (customer?.notes ?? []).sorted { $0.date > $1.date }
                    if projectNotes.isEmpty {
                        Text("Nog geen aantekeningen of foto's toegevoegd.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projectNotes) { note in
                            Button {
                                editingNote = note
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.date, format: .dateTime.day().month().year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(note.text)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                    }
                                    if !note.photoFilenames.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(note.photoFilenames, id: \.self) { filename in
                                                    CustomerPhotoThumbnail(filename: filename)
                                                        .frame(width: 56, height: 56)
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        isAddingNote = true
                    } label: {
                        Label("Notitie / foto toevoegen", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Label("Projecten & foto's", systemImage: "camera")
                }
            }
        }
        .formStyle(.grouped)
        .withKeyboardDismiss()
        .navigationTitle(name.isEmpty ? "Klant" : name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Klant verwijderen", role: .destructive) {
                        confirmDelete = true
                    }
                } label: {
                    Label("Meer", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            guard let customer else { return }
            name = customer.name
            phone = customer.phone
            generalNote = customer.generalNote
        }
        .onChange(of: name) { _, newValue in
            guard var current = customer, current.name != newValue else { return }
            current.name = newValue
            store.update(current)
        }
        .onChange(of: phone) { _, newValue in
            guard var current = customer, current.phone != newValue else { return }
            current.phone = newValue
            store.update(current)
        }
        .onChange(of: generalNote) { _, newValue in
            guard var current = customer, current.generalNote != newValue else { return }
            current.generalNote = newValue
            store.update(current)
        }
        .sheet(item: $editingLine) { line in
            FoilLineEditorSheet(line: line) { updatedLine in
                guard var current = customer else { return }
                if let idx = current.foilLines.firstIndex(where: { $0.id == updatedLine.id }) {
                    current.foilLines[idx] = updatedLine
                    store.update(current)
                }
            } onDelete: {
                deleteLine(line)
            }
        }
        .sheet(isPresented: $isAddingLine) {
            FoilLineEditorSheet(line: CustomerFoilLine()) { newLine in
                guard var current = customer else { return }
                current.foilLines.append(newLine)
                store.update(current)
                ActivityLogStore.shared.log("Folie toegevoegd bij \(current.name)", systemImage: "square.grid.2x2", tab: .klanten, customerID: current.id)
            }
        }
        .sheet(item: $editingNote) { note in
            CustomerNoteEditorSheet(note: note) { updatedNote in
                guard var current = customer else { return }
                if let idx = current.notes.firstIndex(where: { $0.id == updatedNote.id }) {
                    current.notes[idx] = updatedNote
                    store.update(current)
                }
            } onDelete: {
                deleteNote(note)
            }
        }
        .sheet(isPresented: $isAddingNote) {
            CustomerNoteEditorSheet(note: CustomerNote()) { newNote in
                guard var current = customer else { return }
                current.notes.append(newNote)
                store.update(current)
                let hasPhotos = !newNote.photoFilenames.isEmpty
                ActivityLogStore.shared.log(
                    hasPhotos ? "Notitie + foto toegevoegd bij \(current.name)" : "Notitie toegevoegd bij \(current.name)",
                    systemImage: hasPhotos ? "photo.badge.plus" : "note.text.badge.plus",
                    tab: .klanten,
                    customerID: current.id
                )
            }
        }
        .sheet(isPresented: $showMoneybirdPicker) {
            MoneybirdContactPickerSheet(moneybirdSettings: moneybirdSettings) { contact in
                linkMoneybird(contact)
            }
        }
        .confirmationDialog(
            "Klant verwijderen?",
            isPresented: $confirmDelete
        ) {
            Button("Verwijder \(name.isEmpty ? "deze klant" : name)", role: .destructive) {
                if let current = customer {
                    store.delete(current)
                }
                selection = nil
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit verwijdert deze klant en alle folie-regels. Dit kan niet ongedaan worden gemaakt.")
        }
    }

    private func deleteLine(_ line: CustomerFoilLine) {
        guard var current = customer else { return }
        current.foilLines.removeAll { $0.id == line.id }
        store.update(current)
    }

    private func deleteNote(_ note: CustomerNote) {
        guard var current = customer else { return }
        for filename in note.photoFilenames {
            CustomerPhotoStore.delete(filename)
        }
        current.notes.removeAll { $0.id == note.id }
        store.update(current)
    }

    private func linkMoneybird(_ contact: MoneybirdContactLink) {
        guard var current = customer else { return }
        current.moneybirdContact = contact
        if current.name.trimmingCharacters(in: .whitespaces).isEmpty || current.name == "Nieuwe klant" {
            current.name = contact.name
            name = contact.name
        }
        store.update(current)
        ActivityLogStore.shared.log("Klant \(current.name) gekoppeld aan Moneybird", systemImage: "link", tab: .klanten, customerID: current.id)
    }

    private func unlinkMoneybird() {
        guard var current = customer else { return }
        current.moneybirdContact = nil
        store.update(current)
    }
}

private struct FoilLineEditorSheet: View {
    @State var line: CustomerFoilLine
    let onSave: (CustomerFoilLine) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Hoeveelheid") {
                    TextField("Bijv. \u{201c}10 meter\u{201d} of \u{201c}3x\u{201d}", text: $line.amount)
                }
                Section("Materiaal") {
                    TextField("Merk (Oracal, Avery, 3M, Xpel, \u{2026})", text: $line.brand)
                    TextField("Type / artikelcode", text: $line.type)
                    TextField("Kleur", text: $line.color)
                    TextField("Breedte", text: $line.width)
                }
                Section("Notitie") {
                    TextField("Extra opmerking (optioneel)", text: $line.note, axis: .vertical)
                }
                if let onDelete {
                    Section {
                        Button("Regel verwijderen", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .withKeyboardDismiss()
            .navigationTitle("Folie-regel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") {
                        onSave(line)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}


private struct CustomerNoteEditorSheet: View {
    @State var note: CustomerNote
    let onSave: (CustomerNote) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Notitie") {
                    TextEditor(text: $note.text)
                        .frame(minHeight: 120)
                }

                Section("Foto's") {
                    if !note.photoFilenames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(note.photoFilenames, id: \.self) { filename in
                                    ZStack(alignment: .topTrailing) {
                                        CustomerPhotoThumbnail(filename: filename)
                                            .frame(width: 90, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                        Button {
                                            removePhoto(filename)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(4)
                                    }
                                }
                            }
                        }
                    }

                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                        if isLoadingPhotos {
                            ProgressView()
                        } else {
                            Label("Foto's toevoegen", systemImage: "photo.badge.plus")
                        }
                    }
                    .disabled(isLoadingPhotos)
                    .onChange(of: selectedPhotoItems) { _, items in
                        guard !items.isEmpty else { return }
                        isLoadingPhotos = true
                        Task {
                            for item in items {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    let filename = CustomerPhotoStore.save(data)
                                    note.photoFilenames.append(filename)
                                }
                            }
                            selectedPhotoItems = []
                            isLoadingPhotos = false
                        }
                    }
                }

                if let onDelete {
                    Section {
                        Button("Notitie verwijderen", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .withKeyboardDismiss()
            .navigationTitle(onDelete == nil ? "Nieuwe notitie" : "Notitie")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") {
                        onSave(note)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func removePhoto(_ filename: String) {
        note.photoFilenames.removeAll { $0 == filename }
        CustomerPhotoStore.delete(filename)
    }
}

/// Laadt een opgeslagen klantfoto van schijf en toont 'm; laat de ruimte leeg
/// (met een placeholder-icoon) als het bestand niet meer bestaat.
private struct CustomerPhotoThumbnail: View {
    let filename: String

    var body: some View {
        Group {
            if let data = CustomerPhotoStore.load(filename), let image = platformImage(from: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}

private func platformImage(from data: Data) -> Image? {
    #if os(macOS)
    guard let nsImage = NSImage(data: data) else { return nil }
    return Image(nsImage: nsImage)
    #else
    guard let uiImage = UIImage(data: data) else { return nil }
    return Image(uiImage: uiImage)
    #endif
}


private struct MoneybirdContactPickerSheet: View {
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    let onSelect: (MoneybirdContactLink) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MoneybirdContactLink] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if !moneybirdSettings.isConfigured {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Moneybird nog niet ingesteld")
                            .font(.headline)
                        Text("Vul eerst een API-token in bij de Moneybird-instellingen (bij Offerte/montage).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if isSearching {
                    ProgressView("Zoeken\u{2026}")
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if results.isEmpty {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Typ een naam, adres of e-mailadres om te zoeken."
                         : "Geen klanten gevonden voor \u{201c}\(query)\u{201d}.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(results) { contact in
                        Button {
                            onSelect(contact)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .foregroundStyle(.primary)
                                if !contact.address.isEmpty {
                                    Text(contact.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .withKeyboardDismiss()
            .navigationTitle("Koppel Moneybird-klant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Zoek op naam, adres of e-mail")
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    results = []
                    isSearching = false
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await performSearch(trimmed)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    @MainActor
    private func performSearch(_ text: String) async {
        isSearching = true
        errorMessage = nil
        do {
            results = try await MoneybirdExportService.searchContacts(query: text, settings: moneybirdSettings)
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
        isSearching = false
    }
}

// MARK: - Linked customer picker (used on Aanvraag, Offerte, Tinten, Ontchromen, Snijfolie)

struct LinkedCustomerPicker: View {
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @Binding var selectedCustomerID: UUID?
    @State private var showPicker = false

    private var selectedCustomer: Customer? {
        guard let selectedCustomerID else { return nil }
        return customerStore.customers.first { $0.id == selectedCustomerID }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)

            if let customer = selectedCustomer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(customer.name.isEmpty ? "Naamloze klant" : customer.name)
                        .font(.subheadline.weight(.medium))
                    if let contact = customer.moneybirdContact {
                        Label(contact.name, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Niet gekoppeld aan Moneybird")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Wijzig") { showPicker = true }
                    .buttonStyle(.borderless)
                Button {
                    selectedCustomerID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Text("Geen klant gekoppeld")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Klant koppelen") { showPicker = true }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showPicker) {
            CustomerSearchPickerSheet(customerStore: customerStore, moneybirdSettings: moneybirdSettings, selectedCustomerID: $selectedCustomerID)
        }
    }
}

private struct CustomerSearchPickerSheet: View {
    @ObservedObject var customerStore: CustomerStore
    @ObservedObject var moneybirdSettings: MoneybirdSettingsStore
    @Binding var selectedCustomerID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var moneybirdResults: [MoneybirdContactLink] = []
    @State private var isSearchingMoneybird = false
    @State private var moneybirdErrorMessage: String?
    @State private var moneybirdSearchTask: Task<Void, Never>?

    private var filteredLocal: [Customer] {
        let all = customerStore.sortedCustomers
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Moneybird-resultaten die nog geen lokale klant hebben — anders sta je
    /// dubbel in de lijst: één keer als bestaande klant, één keer als
    /// Moneybird-suggestie.
    private var newMoneybirdResults: [MoneybirdContactLink] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return moneybirdResults.filter { contact in
            !customerStore.customers.contains { $0.moneybirdContact?.id == contact.id }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Klanten") {
                    if filteredLocal.isEmpty {
                        Text(customerStore.customers.isEmpty ? "Nog geen klanten aangemaakt." : "Geen klant gevonden.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredLocal) { customer in
                            Button {
                                selectedCustomerID = customer.id
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(customer.name.isEmpty ? "Naamloze klant" : customer.name)
                                        .foregroundStyle(.primary)
                                    if let contact = customer.moneybirdContact {
                                        Label(contact.name, systemImage: "link")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Moneybird") {
                        if !moneybirdSettings.isConfigured {
                            Text("Moneybird is nog niet ingesteld.")
                                .foregroundStyle(.secondary)
                        } else if isSearchingMoneybird {
                            HStack {
                                ProgressView()
                                Text("Zoeken in Moneybird…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let moneybirdErrorMessage {
                            Text(moneybirdErrorMessage)
                                .foregroundStyle(.secondary)
                        } else if newMoneybirdResults.isEmpty {
                            Text("Geen (nieuwe) Moneybird-klanten gevonden.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(newMoneybirdResults) { contact in
                                Button {
                                    selectMoneybirdContact(contact)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.name)
                                            .foregroundStyle(.primary)
                                        if !contact.address.isEmpty {
                                            Text(contact.address)
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
            }
            .searchable(text: $searchText, prompt: "Zoek op klantnaam")
            .onChange(of: searchText) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                moneybirdSearchTask?.cancel()
                moneybirdErrorMessage = nil
                guard moneybirdSettings.isConfigured, !trimmed.isEmpty else {
                    moneybirdResults = []
                    isSearchingMoneybird = false
                    return
                }
                moneybirdSearchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await performMoneybirdSearch(trimmed)
                }
            }
            .withKeyboardDismiss()
            .navigationTitle("Klant koppelen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    @MainActor
    private func performMoneybirdSearch(_ text: String) async {
        isSearchingMoneybird = true
        moneybirdErrorMessage = nil
        do {
            moneybirdResults = try await MoneybirdExportService.searchContacts(query: text, settings: moneybirdSettings)
        } catch {
            moneybirdErrorMessage = error.localizedDescription
            moneybirdResults = []
        }
        isSearchingMoneybird = false
    }

    /// Koppelt een Moneybird-contact: hergebruikt een bestaande klant als die
    /// al aan dit contact gekoppeld is, anders wordt er meteen een nieuwe
    /// klant voor aangemaakt.
    private func selectMoneybirdContact(_ contact: MoneybirdContactLink) {
        if let existing = customerStore.customers.first(where: { $0.moneybirdContact?.id == contact.id }) {
            selectedCustomerID = existing.id
            return
        }
        var new = customerStore.addCustomer(name: contact.name)
        new.moneybirdContact = contact
        customerStore.update(new)
        selectedCustomerID = new.id
        ActivityLogStore.shared.log("Klant \(contact.name) toegevoegd via Moneybird", systemImage: "link", tab: .klanten, customerID: new.id)
    }
}
