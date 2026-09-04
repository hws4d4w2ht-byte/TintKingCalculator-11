import Foundation
import SwiftUI

/// Eén pijl met maatvoering op een foto. Start/eind zijn genormaliseerd
/// (0...1 t.o.v. de fotoafmetingen) zodat de pijl op elk schermformaat op de
/// juiste plek blijft staan, ongeacht hoe groot de foto wordt weergegeven.
///
/// `colorName` is later toegevoegd; de handmatige `init(from:)` zorgt dat
/// oudere, al opgeslagen pijlen zonder dit veld gewoon blijven inladen
/// (vallen terug op geel) in plaats van dat de hele klus niet meer laadt.
struct MeasurementArrow: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
    var label: String = ""
    var colorName: String = "yellow"

    init(id: UUID = UUID(), startX: Double, startY: Double, endX: Double, endY: Double, label: String = "", colorName: String = "yellow") {
        self.id = id
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.label = label
        self.colorName = colorName
    }

    enum CodingKeys: String, CodingKey {
        case id, startX, startY, endX, endY, label, colorName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startX = try container.decode(Double.self, forKey: .startX)
        startY = try container.decode(Double.self, forKey: .startY)
        endX = try container.decode(Double.self, forKey: .endX)
        endY = try container.decode(Double.self, forKey: .endY)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName) ?? "yellow"
    }
}

/// Eén optie in het kleurenpalet voor pijlen. Een eigen (Identifiable)
/// struct in plaats van een los tupel, zodat `ForEach` er zonder gedoe
/// overheen kan lopen.
struct MeasurementArrowColorOption: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}

extension MeasurementArrow {
    /// Vaste kleurenpalet voor pijlen: gekozen op onderlinge herkenbaarheid en
    /// zichtbaarheid tegen uiteenlopende achtergronden (lichte/donkere auto's,
    /// glas, felle zon).
    static let availableColors: [MeasurementArrowColorOption] = [
        MeasurementArrowColorOption(name: "yellow", color: .yellow),
        MeasurementArrowColorOption(name: "red", color: .red),
        MeasurementArrowColorOption(name: "green", color: .green),
        MeasurementArrowColorOption(name: "blue", color: .blue),
        MeasurementArrowColorOption(name: "white", color: .white),
        MeasurementArrowColorOption(name: "black", color: .black),
    ]

    var color: Color {
        MeasurementArrow.availableColors.first(where: { $0.name == colorName })?.color ?? .yellow
    }
}

/// Eén foto binnen een klus, met de pijlen/maten die erop getekend zijn.
struct MeasurementPhoto: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Bestandsnaam van de JPEG op schijf (in de MeasurementPhotos-map),
    /// bijvoorbeeld "<uuid>.jpg". De foto zelf staat dus niet in dit bestand
    /// (en dus ook niet in de JSON-lijst met klussen), om die klein te houden.
    var fileName: String
    var arrows: [MeasurementArrow] = []
    var createdAt: Date = Date()
}

/// Eén "klus": een verzameling gemeten foto's bij elkaar, bijvoorbeeld voor
/// één opdracht of auto.
///
/// `note` is later toegevoegd (adres/kenteken/opmerking); de handmatige
/// `init(from:)` zorgt dat al opgeslagen klussen zonder dit veld gewoon
/// blijven inladen in plaats van te mislukken.
struct MeasurementProject: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var note: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var photos: [MeasurementPhoto] = []

    init(id: UUID = UUID(), name: String = "", note: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(), photos: [MeasurementPhoto] = []) {
        self.id = id
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.photos = photos
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note, createdAt, modifiedAt, photos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        photos = try container.decodeIfPresent([MeasurementPhoto].self, forKey: .photos) ?? []
    }

    var displayName: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Naamloze klus" : cleaned
    }
}
