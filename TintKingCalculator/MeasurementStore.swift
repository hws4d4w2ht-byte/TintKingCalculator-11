import Foundation
import SwiftUI
#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    /// Cross-platform init zodat UI-code niet steeds #if os(iOS) hoeft te doen
    /// om van een PlatformImage een SwiftUI Image te maken.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// JPEG-data van deze afbeelding, cross-platform (UIImage heeft dit
    /// standaard, NSImage moet via een bitmap-representatie).
    func measurementJPEGData(quality: CGFloat = 0.85) -> Data? {
        #if os(iOS)
        return jpegData(compressionQuality: quality)
        #else
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    /// Pixelafmetingen van de afbeelding (op de Mac is `size` in punten, niet
    /// per se pixels, dus daar rekenen we via de bitmap-representatie).
    var measurementPixelSize: CGSize {
        #if os(iOS)
        return CGSize(width: size.width * scale, height: size.height * scale)
        #else
        if let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
        #endif
    }
}

/// Beheert de "Meten"-klussen: een lijst gemeten foto's (met pijlen/maten)
/// per klus. Foto's zelf staan als losse JPEG-bestanden op schijf; alleen de
/// pijlen/maten en bestandsnamen worden in één JSON-bestand bewaard.
///
/// Bewust (nog) zonder iCloud-synchronisatie: die staat voor de rest van de
/// app momenteel uit (CloudSyncConfig.isEnabled = false) in afwachting van een
/// actief betaald Apple Developer-account, en foto's synchroniseren vraagt
/// nogal wat extra CloudKit-werk (CKAsset) dat pas zin heeft als dat account
/// actief is. De klussen blijven gewoon lokaal bewaard, net als al het andere
/// op dit moment.
@MainActor
final class MeasurementStore: ObservableObject {
    @Published private(set) var projects: [MeasurementProject] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let photosFolder: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("TintKingCalculator", isDirectory: true)
        let photos = folder.appendingPathComponent("MeasurementPhotos", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("measurements.json")
        photosFolder = photos
        load()
    }

    func clearError() {
        lastError = nil
    }

    func project(id: UUID?) -> MeasurementProject? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
    }

    @discardableResult
    func createProject(name: String) -> UUID {
        let project = MeasurementProject(name: name)
        projects.append(project)
        sortProjects()
        persist()
        return project.id
    }

    func renameProject(id: UUID, name: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        projects[index].modifiedAt = Date()
        persist()
    }

    /// Vrije notitie per klus (bijv. adres of kenteken), los van de naam.
    func updateNote(id: UUID, note: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].note = note
        projects[index].modifiedAt = Date()
        persist()
    }

    func deleteProject(id: UUID) {
        guard let project = project(id: id) else { return }
        for photo in project.photos {
            try? FileManager.default.removeItem(at: photosFolder.appendingPathComponent(photo.fileName))
        }
        projects.removeAll { $0.id == id }
        persist()
    }

    /// Voegt een nieuwe foto toe aan een klus en slaat de afbeelding als JPEG
    /// op schijf op.
    @discardableResult
    func addPhoto(to projectID: UUID, image: PlatformImage) -> UUID? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        guard let data = image.measurementJPEGData() else {
            lastError = "Kon de foto niet opslaan."
            return nil
        }
        let photo = MeasurementPhoto(fileName: "\(UUID().uuidString).jpg")
        do {
            try data.write(to: photosFolder.appendingPathComponent(photo.fileName), options: [.atomic])
        } catch {
            lastError = "Kon de foto niet opslaan: \(error.localizedDescription)"
            return nil
        }
        projects[index].photos.append(photo)
        projects[index].modifiedAt = Date()
        persist()
        return photo.id
    }

    func deletePhoto(projectID: UUID, photoID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let photo = projects[index].photos.first(where: { $0.id == photoID }) {
            try? FileManager.default.removeItem(at: photosFolder.appendingPathComponent(photo.fileName))
        }
        projects[index].photos.removeAll { $0.id == photoID }
        projects[index].modifiedAt = Date()
        persist()
    }

    /// Herschikt de volgorde van foto's binnen een klus (bijv. via een
    /// sleep-lijstje). `from`/`to` komen rechtstreeks van SwiftUI's
    /// `.onMove`.
    func movePhotos(projectID: UUID, from: IndexSet, to: Int) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].photos.move(fromOffsets: from, toOffset: to)
        projects[index].modifiedAt = Date()
        persist()
    }

    /// Vervangt alle pijlen/maten van één foto (bijv. na bewerken in de
    /// editor) en slaat direct op.
    func updateArrows(projectID: UUID, photoID: UUID, arrows: [MeasurementArrow]) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard let phIndex = projects[pIndex].photos.firstIndex(where: { $0.id == photoID }) else { return }
        projects[pIndex].photos[phIndex].arrows = arrows
        projects[pIndex].modifiedAt = Date()
        persist()
    }

    func imageURL(for photo: MeasurementPhoto) -> URL {
        photosFolder.appendingPathComponent(photo.fileName)
    }

    func loadImage(for photo: MeasurementPhoto) -> PlatformImage? {
        guard let data = try? Data(contentsOf: imageURL(for: photo)) else { return nil }
        return PlatformImage(data: data)
    }

    /// Rendert de foto + pijlen op volledige resolutie tot een platte JPEG in
    /// een tijdelijk bestand, klaar om te delen (bijv. via ShareLink). Wordt
    /// gebruikt voor zowel het delen van één foto als "deel alle foto's" van
    /// een klus in één keer.
    func flattenedJPEGURL(for photo: MeasurementPhoto) -> URL? {
        guard let image = loadImage(for: photo) else { return nil }
        let renderer = ImageRenderer(content: MeasurementFlattenedView(image: image, arrows: photo.arrows))
        renderer.scale = 1
        #if os(iOS)
        guard let rendered = renderer.uiImage else { return nil }
        #else
        guard let rendered = renderer.nsImage else { return nil }
        #endif
        guard let data = rendered.measurementJPEGData(quality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meting-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    private func sortProjects() {
        projects.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            projects = try JSONDecoder().decode([MeasurementProject].self, from: data)
            sortProjects()
            lastError = nil
        } catch {
            lastError = "Klussen konden niet worden geladen: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: [.atomic])
            sortProjects()
            lastError = nil
        } catch {
            lastError = "Klus kon niet worden opgeslagen: \(error.localizedDescription)"
        }
    }
}
