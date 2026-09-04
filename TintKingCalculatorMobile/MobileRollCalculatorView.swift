import SwiftUI
import UIKit

private struct MobileCutPlannerLine: Identifiable, Hashable {
    let id: UUID
    var widthCm: Double
    var quantity: Int

    init(id: UUID = UUID(), widthCm: Double = 0, quantity: Int = 1) {
        self.id = id
        self.widthCm = widthCm
        self.quantity = quantity
    }
}

/// Mobiele versie van de Rolcalculator (snijplanner + foliecalculator) van de Mac-app.
struct MobileRollCalculatorView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case cut = "Snijplanner"
        case foil = "Folie"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .cut

    // Snijplanner
    @State private var maxWidthCm: Double = 152
    @State private var cutLines: [MobileCutPlannerLine] = [MobileCutPlannerLine(widthCm: 0, quantity: 1)]

    // Folie
    @State private var rollWidthCm: Double = 152
    @State private var rollLengthM: Double = 25
    @State private var rollCount: Int = 1
    @State private var wastePercent: Double = 10

    private var usedWidthCm: Double {
        cutLines.reduce(0) { partial, line in partial + max(line.widthCm, 0) * Double(max(line.quantity, 0)) }
    }

    private var remainingWidthCm: Double { maxWidthCm - usedWidthCm }

    private var baseLinearMeters: Double { max(rollLengthM, 0) * Double(max(rollCount, 0)) }

    private var linearMetersWithWaste: Double { baseLinearMeters * (1 + max(wastePercent, 0) / 100.0) }

    private var areaWithWaste: Double { (max(rollWidthCm, 0) / 100.0) * linearMetersWithWaste }

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL"))
    }

    private var cutResultText: String {
        var lines: [String] = ["Snijplanner", "Max breedte: \(maxWidthCm.formatted(numberFormat)) cm", ""]
        for line in cutLines where line.widthCm > 0 && line.quantity > 0 {
            lines.append("• \(line.quantity)x \(line.widthCm.formatted(numberFormat)) cm")
        }
        lines.append("")
        lines.append("Gebruikt: \(usedWidthCm.formatted(numberFormat)) cm")
        lines.append("Resterend: \(remainingWidthCm.formatted(numberFormat)) cm")
        return lines.joined(separator: "\n")
    }

    private var foilResultText: String {
        """
        Folie calculator
        Rolbreedte: \(rollWidthCm.formatted(numberFormat)) cm
        Lengte per rol: \(rollLengthM.formatted(numberFormat)) m
        Aantal rollen: \(rollCount)
        Snijverlies: \(wastePercent.formatted(numberFormat))%

        Strekkende meters zonder snijverlies: \(baseLinearMeters.formatted(numberFormat)) m
        Strekkende meters incl. snijverlies: \(linearMetersWithWaste.formatted(numberFormat)) m
        Oppervlak incl. snijverlies: \(areaWithWaste.formatted(numberFormat)) m²
        """
    }

    var body: some View {
        List {
            Section {
                Picker("Calculator", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            if mode == .cut {
                cutPlannerSections
            } else {
                foilCalculatorSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Rolcalculator")
    }

    @ViewBuilder
    private var cutPlannerSections: some View {
        Section("Max breedte") {
            HStack {
                Text("Max breedte")
                Spacer()
                AppNumberField(placeholder: "152", value: $maxWidthCm)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                Text("cm")
            }
        }

        Section("Maten & aantallen") {
            ForEach($cutLines) { $line in
                let index = cutLines.firstIndex(where: { $0.id == line.id }) ?? 0
                HStack(spacing: 10) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    AppNumberField(placeholder: "Breedte", value: $line.widthCm)
                        .frame(width: 80)
                    Text("cm")

                    Spacer()

                    Stepper(value: $line.quantity, in: 1...999) {
                        Text("\(line.quantity)x")
                    }

                    Button(role: .destructive) {
                        cutLines.removeAll { $0.id == line.id }
                        if cutLines.isEmpty {
                            cutLines = [MobileCutPlannerLine(widthCm: 0, quantity: 1)]
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                cutLines.append(MobileCutPlannerLine(widthCm: 0, quantity: 1))
            } label: {
                Label("Regel toevoegen", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                maxWidthCm = 152
                cutLines = [MobileCutPlannerLine(widthCm: 0, quantity: 1)]
            } label: {
                Label("Alles resetten", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
        }

        Section("Resultaat") {
            MobileMetric(title: "Gebruikt", value: "\(usedWidthCm.formatted(numberFormat)) cm")
            MobileMetric(title: "Resterend", value: "\(remainingWidthCm.formatted(numberFormat)) cm")

            if remainingWidthCm < 0 {
                Label(
                    "Je zit \(abs(remainingWidthCm).formatted(numberFormat)) cm over de maximale breedte.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            Button {
                UIPasteboard.general.string = cutResultText
            } label: {
                Label("Kopieer snij-resultaat", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var foilCalculatorSections: some View {
        Section("Folie calculator") {
            HStack {
                Text("Rolbreedte")
                Spacer()
                AppNumberField(placeholder: "152", value: $rollWidthCm)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("cm")
            }
            HStack {
                Text("Lengte per rol")
                Spacer()
                AppNumberField(placeholder: "25", value: $rollLengthM)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("m")
            }
            Stepper(value: $rollCount, in: 1...999) {
                HStack {
                    Text("Aantal rollen")
                    Spacer()
                    Text("\(rollCount)")
                }
            }
            HStack {
                Text("Snijverlies")
                Spacer()
                AppNumberField(placeholder: "10", value: $wastePercent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("%")
            }

            Button {
                rollWidthCm = 152
                rollLengthM = 25
                rollCount = 1
                wastePercent = 10
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }

        Section("Resultaat") {
            MobileMetric(title: "Strekkende meters zonder snijverlies", value: "\(baseLinearMeters.formatted(numberFormat)) m")
            MobileMetric(title: "Strekkende meters incl. snijverlies", value: "\(linearMetersWithWaste.formatted(numberFormat)) m")
            MobileMetric(title: "Oppervlak incl. snijverlies", value: "\(areaWithWaste.formatted(numberFormat)) m²")

            Button {
                UIPasteboard.general.string = foilResultText
            } label: {
                Label("Kopieer folie-resultaat", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Tip: als je een rol splitst in meerdere kleine rollen, vul je bij 'Aantal rollen' het aantal deelrollen in en bij 'Lengte per rol' de lengte van één deelrol.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
