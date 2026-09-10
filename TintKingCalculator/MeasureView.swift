import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// "Meten" tabblad: maak/bewaar foto's per klus en zet er pijlen met maten
/// overheen — geïnspireerd op meetprogramma's als mymeasuresapp.com, maar
/// zonder AR-camera of laser (DISTO) integratie: puur foto + handmatig
/// ingetekende pijl + tekstlabel. Werkt volledig lokaal (geen cloud-sync,
/// net als de rest van de app zolang CloudSync uitstaat).

// MARK: - Navigatie-routes
// Losse Hashable-types voor klus- en foto-navigatie: anders botsen ze omdat
// beide een UUID zouden zijn binnen dezelfde NavigationStack, waardoor een
// tik op een foto de verkeerde (klus-)bestemming zou triggeren.
struct MeasurementProjectRoute: Hashable {
    let id: UUID
}

struct MeasurementPhotoRoute: Hashable {
    let id: UUID
}

// MARK: - Klussenlijst

struct MeasureView: View {
    @ObservedObject var store: MeasurementStore

    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    var body: some View {
        List {
            if store.projects.isEmpty {
                ContentUnavailableView(
                    "Nog geen klussen",
                    systemImage: "ruler",
                    description: Text("Maak een klus aan en voeg er foto's aan toe om maten in te tekenen.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.projects) { project in
                    NavigationLink(value: MeasurementProjectRoute(id: project.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.displayName)
                                .fontWeight(.semibold)
                            Text(project.photos.isEmpty ? "Geen foto's" : "\(project.photos.count) foto\(project.photos.count == 1 ? "" : "'s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteProject(id: project.id)
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            store.deleteProject(id: project.id)
                        } label: {
                            Label("Verwijder klus", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .withKeyboardDismiss()
        .navigationTitle("Meten")
        .navigationDestination(for: MeasurementProjectRoute.self) { route in
            MeasurementProjectDetailView(store: store, projectID: route.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newProjectName = ""
                    showNewProjectAlert = true
                } label: {
                    Label("Nieuwe klus", systemImage: "plus")
                }
            }
        }
        .alert("Nieuwe klus", isPresented: $showNewProjectAlert) {
            TextField("Naam (bijv. klant of kenteken)", text: $newProjectName)
            Button("Annuleer", role: .cancel) { }
            Button("Aanmaken") {
                _ = store.createProject(name: newProjectName)
            }
        } message: {
            Text("Geef de klus een naam zodat je hem later terugvindt.")
        }
        .alert("Fout", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

// MARK: - Foto's binnen een klus

struct MeasurementProjectDetailView: View {
    @ObservedObject var store: MeasurementStore
    let projectID: UUID

    @State private var showEditAlert = false
    @State private var nameText = ""
    @State private var noteText = ""
    @State private var showReorderSheet = false
    @State private var shareAllURLs: [URL] = []
    #if os(iOS)
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showAddPhotoOptions = false
    @State private var showPhotosPicker = false
    #endif
    @State private var showFileImporter = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    private var project: MeasurementProject? { store.project(id: projectID) }

    var body: some View {
        VStack(spacing: 0) {
            if let project, !project.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(project.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            ScrollView {
                if let project, !project.photos.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(project.photos) { photo in
                            NavigationLink(value: MeasurementPhotoRoute(id: photo.id)) {
                                MeasurementPhotoThumbnail(store: store, photo: photo)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.deletePhoto(projectID: projectID, photoID: photo.id)
                                } label: {
                                    Label("Verwijder foto", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(16)
                } else {
                    ContentUnavailableView(
                        "Nog geen foto's",
                        systemImage: "photo.badge.plus",
                        description: Text("Voeg een foto toe om er pijlen en maten op te tekenen.")
                    )
                    .padding(.top, 60)
                }
            }
        }
        .withKeyboardDismiss()
        .navigationTitle(project?.displayName ?? "Klus")
        .navigationDestination(for: MeasurementPhotoRoute.self) { route in
            if let project, let photo = project.photos.first(where: { $0.id == route.id }) {
                MeasurementAnnotationView(store: store, projectID: projectID, photo: photo)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addPhotoButton
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button {
                        nameText = project?.name ?? ""
                        noteText = project?.note ?? ""
                        showEditAlert = true
                    } label: {
                        Label("Klus bewerken", systemImage: "pencil")
                    }
                    if let project, project.photos.count > 1 {
                        Button {
                            showReorderSheet = true
                        } label: {
                            Label("Foto's herschikken", systemImage: "arrow.up.arrow.down")
                        }
                        if !shareAllURLs.isEmpty {
                            ShareLink(items: shareAllURLs) {
                                Label("Deel alle foto's", systemImage: "square.and.arrow.up.on.square")
                            }
                        }
                    }
                } label: {
                    Label("Meer", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Klus bewerken", isPresented: $showEditAlert) {
            TextField("Naam", text: $nameText)
            TextField("Notitie (adres, kenteken, ...)", text: $noteText)
            Button("Annuleer", role: .cancel) { }
            Button("Opslaan") {
                store.renameProject(id: projectID, name: nameText)
                store.updateNote(id: projectID, note: noteText)
            }
        }
        .sheet(isPresented: $showReorderSheet) {
            MeasurementPhotoReorderSheet(store: store, projectID: projectID)
        }
        .onAppear {
            prepareShareAllIfNeeded()
        }
        .onChange(of: project?.photos) { _, _ in
            prepareShareAllIfNeeded()
        }
        #if os(iOS)
        .confirmationDialog("Foto toevoegen", isPresented: $showAddPhotoOptions) {
            Button("Camera") { showCamera = true }
            Button("Kies uit bibliotheek") { showPhotosPicker = true }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = PlatformImage(data: data) {
                    store.addPhoto(to: projectID, image: image)
                }
                photosPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            MeasurementCameraCapture { image in
                if let image {
                    store.addPhoto(to: projectID, image: image)
                }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        #else
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) {
                        store.addPhoto(to: projectID, image: image)
                    }
                }
            }
        }
        #endif
    }

    private func prepareShareAllIfNeeded() {
        shareAllURLs = (project?.photos ?? []).compactMap { store.flattenedJPEGURL(for: $0) }
    }

    @ViewBuilder
    private var addPhotoButton: some View {
        #if os(iOS)
        Button {
            showAddPhotoOptions = true
        } label: {
            Label("Foto toevoegen", systemImage: "plus")
        }
        #else
        Button {
            showFileImporter = true
        } label: {
            Label("Foto toevoegen", systemImage: "plus")
        }
        #endif
    }
}

struct MeasurementPhotoThumbnail: View {
    @ObservedObject var store: MeasurementStore
    let photo: MeasurementPhoto

    var body: some View {
        Group {
            if let image = store.loadImage(for: photo) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if !photo.arrows.isEmpty {
                Text("\(photo.arrows.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
    }
}

/// Sleep-lijstje om de volgorde van foto's binnen een klus aan te passen.
/// Losstaand van de grid-weergave omdat `LazyVGrid` geen ingebouwde
/// drag-to-reorder heeft — een `List` met `.onMove` wel.
struct MeasurementPhotoReorderSheet: View {
    @ObservedObject var store: MeasurementStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss

    private var photos: [MeasurementPhoto] {
        store.project(id: projectID)?.photos ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(photos) { photo in
                    HStack(spacing: 12) {
                        if let image = store.loadImage(for: photo) {
                            Image(platformImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.quaternary)
                                .frame(width: 44, height: 44)
                        }
                        Text(photo.arrows.isEmpty ? "Geen maten" : "\(photo.arrows.count) maat\(photo.arrows.count == 1 ? "" : "en")")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { indices, newOffset in
                    store.movePhotos(projectID: projectID, from: indices, to: newOffset)
                }
            }
            .withKeyboardDismiss()
            .navigationTitle("Foto's herschikken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar") { dismiss() }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
    }
}

// MARK: - Maat en kleur van een pijl bewerken

/// Klein formulier voor het label (de maat) en de kleur van een pijl. Zit in
/// een sheet in plaats van een `.alert`, omdat een alert geen kleurenkiezer
/// kan bevatten.
struct MeasurementArrowEditorSheet: View {
    @Binding var labelText: String
    @Binding var colorName: String
    var isEditingExisting: Bool
    var onSave: () -> Void
    var onDelete: (() -> Void)?
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Maat") {
                    TextField("bijv. 120 cm", text: $labelText)
                }
                Section("Kleur") {
                    HStack(spacing: 14) {
                        ForEach(MeasurementArrow.availableColors) { option in
                            Circle()
                                .fill(option.color)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: colorName == option.name ? 3 : 1)
                                )
                                .onTapGesture { colorName = option.name }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if isEditingExisting, let onDelete {
                    Section {
                        Button("Verwijder pijl", role: .destructive, action: onDelete)
                    }
                }
            }
            .withKeyboardDismiss()
            .navigationTitle(isEditingExisting ? "Maat aanpassen" : "Maat invoeren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan", action: onSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 340)
        #endif
    }
}

// MARK: - Pijlen intekenen op een foto

private enum AnnotationInteractionMode {
    case draw
    case panZoom
}

/// De kern van het Meten-tabblad: toont de foto op ware schaal binnen het
/// scherm en laat je pijlen tekenen (sleep vanuit een leeg stuk van de foto),
/// bestaande pijlen verslepen aan hun uiteinden, en het label (de maat) en de
/// kleur aanpassen door op de badge te tikken. Via de knop rechtsboven schakel
/// je om naar knijpen-om-te-zoomen + slepen-om-te-verschuiven, handig om
/// precies te tikken bij foto's met meerdere maten dicht bij elkaar.
struct MeasurementAnnotationView: View {
    @ObservedObject var store: MeasurementStore
    let projectID: UUID
    let photo: MeasurementPhoto

    @State private var image: PlatformImage?
    @State private var arrows: [MeasurementArrow] = []
    @State private var draftStart: CGPoint?
    @State private var draftCurrent: CGPoint?
    @State private var pendingNormalizedArrow: (start: CGPoint, end: CGPoint)?
    @State private var editingArrowID: UUID?
    @State private var labelText = ""
    @State private var editingColorName = "yellow"
    @State private var lastUsedColorName = "yellow"
    @State private var showLabelAlert = false
    @State private var shareURL: URL?

    @State private var interactionMode: AnnotationInteractionMode = .draw
    @State private var zoomScale: CGFloat = 1
    @State private var zoomScaleDelta: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panOffsetDelta: CGSize = .zero

    private let handleDiameter: CGFloat = 22

    private var currentZoom: CGFloat { zoomScale * zoomScaleDelta }
    private var currentPan: CGSize {
        CGSize(width: panOffset.width + panOffsetDelta.width, height: panOffset.height + panOffsetDelta.height)
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let containerSize = geo.size
                let imgSize = image?.measurementPixelSize ?? containerSize
                let rect = displayRect(containerSize: containerSize, imageSize: imgSize)

                annotationContent(containerSize: containerSize, rect: rect)
                    .scaleEffect(currentZoom, anchor: .center)
                    .offset(currentPan)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(interactionGesture(rect: rect))
            }
            .background(Color.black)

            VStack {
                Spacer()
                Text(interactionMode == .draw ? "Sleep om een pijl te tekenen" : "Knijp om te zoomen · sleep om te verschuiven")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
            }
            .allowsHitTesting(false)
        }
        .withKeyboardDismiss()
        .navigationTitle("Maat intekenen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Delen", systemImage: "square.and.arrow.up")
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    interactionMode = interactionMode == .draw ? .panZoom : .draw
                } label: {
                    Label(
                        interactionMode == .draw ? "Zoomen/verschuiven" : "Pijl tekenen",
                        systemImage: interactionMode == .draw ? "arrow.up.left.and.arrow.down.right.magnifyingglass" : "pencil.tip"
                    )
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                if zoomScale > 1.01 || abs(panOffset.width) > 0.5 || abs(panOffset.height) > 0.5 {
                    Button {
                        resetZoom()
                    } label: {
                        Label("Zoom resetten", systemImage: "arrow.counterclockwise.circle")
                    }
                }
            }
        }
        .onAppear {
            image = store.loadImage(for: photo)
            arrows = photo.arrows
            regenerateShareFile()
        }
        .sheet(isPresented: $showLabelAlert) {
            MeasurementArrowEditorSheet(
                labelText: $labelText,
                colorName: $editingColorName,
                isEditingExisting: editingArrowID != nil,
                onSave: {
                    commitLabel()
                    showLabelAlert = false
                },
                onDelete: editingArrowID != nil ? {
                    if let id = editingArrowID {
                        arrows.removeAll { $0.id == id }
                        persist()
                    }
                    editingArrowID = nil
                    pendingNormalizedArrow = nil
                    showLabelAlert = false
                } : nil,
                onCancel: {
                    editingArrowID = nil
                    pendingNormalizedArrow = nil
                    showLabelAlert = false
                }
            )
        }
    }

    private func resetZoom() {
        zoomScale = 1
        zoomScaleDelta = 1
        panOffset = .zero
        panOffsetDelta = .zero
    }

    @ViewBuilder
    private func annotationContent(containerSize: CGSize, rect: CGRect) -> some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: containerSize.width, height: containerSize.height)
            } else {
                ProgressView()
                    .frame(width: containerSize.width, height: containerSize.height)
            }

            Canvas { context, _ in
                for arrow in arrows {
                    let start = point(for: CGPoint(x: arrow.startX, y: arrow.startY), in: rect)
                    let end = point(for: CGPoint(x: arrow.endX, y: arrow.endY), in: rect)
                    stroke(from: start, to: end, in: context, color: arrow.color, dashed: false)
                }
                if let draftStart, let draftCurrent {
                    stroke(from: draftStart, to: draftCurrent, in: context, color: .white, dashed: true)
                }
            }
            .allowsHitTesting(false)

            ForEach(arrows) { arrow in
                let startPoint = point(for: CGPoint(x: arrow.startX, y: arrow.startY), in: rect)
                let endPoint = point(for: CGPoint(x: arrow.endX, y: arrow.endY), in: rect)

                labelBadge(for: arrow, at: midpoint(startPoint, endPoint))

                if interactionMode == .draw {
                    handle(at: startPoint, arrowID: arrow.id, isStart: true, rect: rect)
                    handle(at: endPoint, arrowID: arrow.id, isStart: false, rect: rect)
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    private func interactionGesture(rect: CGRect) -> AnyGesture<Void> {
        switch interactionMode {
        case .draw:
            return AnyGesture(drawGesture(rect: rect).map { _ in () })
        case .panZoom:
            return AnyGesture(panZoomGesture.map { _ in () })
        }
    }

    private func drawGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if draftStart == nil { draftStart = value.startLocation }
                draftCurrent = value.location
            }
            .onEnded { value in
                let start = value.startLocation
                let end = value.location
                draftStart = nil
                draftCurrent = nil
                let distance = hypot(end.x - start.x, end.y - start.y)
                guard distance > 24 else { return }
                pendingNormalizedArrow = (normalizedPoint(for: start, in: rect), normalizedPoint(for: end, in: rect))
                editingArrowID = nil
                labelText = ""
                editingColorName = lastUsedColorName
                showLabelAlert = true
            }
    }

    private var panZoomGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in zoomScaleDelta = value }
                .onEnded { value in
                    zoomScale = min(max(zoomScale * value, 1), 6)
                    zoomScaleDelta = 1
                },
            DragGesture(minimumDistance: 0)
                .onChanged { value in panOffsetDelta = value.translation }
                .onEnded { value in
                    panOffset.width += value.translation.width
                    panOffset.height += value.translation.height
                    panOffsetDelta = .zero
                }
        )
    }

    private func commitLabel() {
        if let id = editingArrowID, let index = arrows.firstIndex(where: { $0.id == id }) {
            arrows[index].label = labelText
            arrows[index].colorName = editingColorName
        } else if let pending = pendingNormalizedArrow {
            let arrow = MeasurementArrow(
                startX: pending.start.x, startY: pending.start.y,
                endX: pending.end.x, endY: pending.end.y,
                label: labelText,
                colorName: editingColorName
            )
            arrows.append(arrow)
        }
        lastUsedColorName = editingColorName
        editingArrowID = nil
        pendingNormalizedArrow = nil
        persist()
    }

    private func persist() {
        store.updateArrows(projectID: projectID, photoID: photo.id, arrows: arrows)
        regenerateShareFile()
    }

    private func regenerateShareFile() {
        guard let image else { return }
        let renderer = ImageRenderer(content: MeasurementFlattenedView(image: image, arrows: arrows))
        renderer.scale = 1
        #if os(iOS)
        guard let rendered = renderer.uiImage else { return }
        #else
        guard let rendered = renderer.nsImage else { return }
        #endif
        guard let data = rendered.measurementJPEGData(quality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meting-\(UUID().uuidString).jpg")
        try? data.write(to: url)
        shareURL = url
    }

    @ViewBuilder
    private func handle(at location: CGPoint, arrowID: UUID, isStart: Bool, rect: CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
            .frame(width: handleDiameter, height: handleDiameter)
            .position(location)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let index = arrows.firstIndex(where: { $0.id == arrowID }) else { return }
                        let n = normalizedPoint(for: value.location, in: rect)
                        if isStart {
                            arrows[index].startX = n.x
                            arrows[index].startY = n.y
                        } else {
                            arrows[index].endX = n.x
                            arrows[index].endY = n.y
                        }
                    }
                    .onEnded { _ in persist() }
            )
    }

    @ViewBuilder
    private func labelBadge(for arrow: MeasurementArrow, at location: CGPoint) -> some View {
        HStack(spacing: 5) {
            Circle().fill(arrow.color).frame(width: 8, height: 8)
            Text(arrow.label.isEmpty ? "?" : arrow.label)
                .font(.caption.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.7), in: Capsule())
        .foregroundStyle(.white)
        .position(location)
        .onTapGesture {
            guard interactionMode == .draw else { return }
            editingArrowID = arrow.id
            labelText = arrow.label
            editingColorName = arrow.colorName
            pendingNormalizedArrow = nil
            showLabelAlert = true
        }
    }

    private func stroke(from start: CGPoint, to end: CGPoint, in context: GraphicsContext, color: Color, dashed: Bool) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, dash: dashed ? [8, 6] : [])
        context.stroke(path, with: .color(color), style: style)

        guard !dashed else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 14
        let headAngle: CGFloat = .pi / 7
        let p1 = CGPoint(x: end.x - headLength * cos(angle - headAngle), y: end.y - headLength * sin(angle - headAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + headAngle), y: end.y - headLength * sin(angle + headAngle))
        var headPath = Path()
        headPath.move(to: end)
        headPath.addLine(to: p1)
        headPath.move(to: end)
        headPath.addLine(to: p2)
        context.stroke(headPath, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func displayRect(containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let containerAspect = containerSize.width / containerSize.height
        let imageAspect = imageSize.width / imageSize.height
        if imageAspect > containerAspect {
            let width = containerSize.width
            let height = width / imageAspect
            return CGRect(x: 0, y: (containerSize.height - height) / 2, width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * imageAspect
            return CGRect(x: (containerSize.width - width) / 2, y: 0, width: width, height: height)
        }
    }

    private func point(for normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    private func normalizedPoint(for location: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = (location.x - rect.minX) / rect.width
        let y = (location.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// Platte weergave van foto + pijlen op volledige (pixel)resolutie, gebruikt
/// om een deelbare afbeelding te renderen via `ImageRenderer`. Losstaand van
/// de interactieve editor hierboven zodat het scherm-formaat van het scherm
/// nooit de kwaliteit van het gedeelde eindresultaat beperkt.
struct MeasurementFlattenedView: View {
    let image: PlatformImage
    let arrows: [MeasurementArrow]

    private var canvasSize: CGSize {
        let size = image.measurementPixelSize
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1200, height: 900)
    }

    var body: some View {
        let size = canvasSize
        ZStack {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Canvas { context, _ in
                let lineWidth = max(size.width, size.height) * 0.004
                let fontSize = max(size.width, size.height) * 0.022
                let headLength = max(size.width, size.height) * 0.02
                let headAngle: CGFloat = .pi / 7

                for arrow in arrows {
                    let start = CGPoint(x: arrow.startX * size.width, y: arrow.startY * size.height)
                    let end = CGPoint(x: arrow.endX * size.width, y: arrow.endY * size.height)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let color = arrow.color

                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                    let p1 = CGPoint(x: end.x - headLength * cos(angle - headAngle), y: end.y - headLength * sin(angle - headAngle))
                    let p2 = CGPoint(x: end.x - headLength * cos(angle + headAngle), y: end.y - headLength * sin(angle + headAngle))
                    var headPath = Path()
                    headPath.move(to: end)
                    headPath.addLine(to: p1)
                    headPath.move(to: end)
                    headPath.addLine(to: p2)
                    context.stroke(headPath, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                    guard !arrow.label.isEmpty else { continue }
                    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    let approxWidth = CGFloat(arrow.label.count) * fontSize * 0.62 + fontSize
                    let approxHeight = fontSize * 1.7
                    let bgRect = CGRect(x: mid.x - approxWidth / 2, y: mid.y - approxHeight / 2, width: approxWidth, height: approxHeight)
                    context.fill(Path(roundedRect: bgRect, cornerRadius: approxHeight / 2), with: .color(.black.opacity(0.65)))
                    let text = Text(arrow.label).font(.system(size: fontSize, weight: .bold)).foregroundStyle(.white)
                    context.draw(text, at: mid)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }
}

#if os(iOS)
/// Minimale camera-opname via UIImagePickerController, want SwiftUI heeft
/// (nog) geen native camera-opname view. Alleen gebruikt op iOS.
import UIKit

struct MeasurementCameraCapture: UIViewControllerRepresentable {
    var onCapture: (PlatformImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (PlatformImage?) -> Void
        init(onCapture: @escaping (PlatformImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
