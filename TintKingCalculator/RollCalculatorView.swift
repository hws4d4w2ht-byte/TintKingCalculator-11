import SwiftUI
import AppKit

struct CutPlannerLine: Identifiable, Hashable {
    let id: UUID
    var widthCm: Double
    var quantity: Int

    init(id: UUID = UUID(), widthCm: Double = 0, quantity: Int = 1) {
        self.id = id
        self.widthCm = widthCm
        self.quantity = quantity
    }
}

struct RollCalculatorView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case cut = "Snijplanner"
        case foil = "Folie"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .cut

    // Snijplanner
    @State private var maxWidthCm: Double = 152
    @State private var cutLines: [CutPlannerLine] = [
        CutPlannerLine(widthCm: 0, quantity: 1)
    ]

    // Folie
    @State private var rollWidthCm: Double = 152
    @State private var rollLengthM: Double = 25
    @State private var rollCount: Int = 1
    @State private var wastePercent: Double = 10

    private var usedWidthCm: Double {
        cutLines.reduce(0) { partial, line in
            partial + max(line.widthCm, 0) * Double(max(line.quantity, 0))
        }
    }

    private var remainingWidthCm: Double {
        maxWidthCm - usedWidthCm
    }

    private var baseLinearMeters: Double {
        max(rollLengthM, 0) * Double(max(rollCount, 0))
    }

    private var linearMetersWithWaste: Double {
        baseLinearMeters * (1 + max(wastePercent, 0) / 100.0)
    }

    private var areaWithWaste: Double {
        (max(rollWidthCm, 0) / 100.0) * linearMetersWithWaste
    }

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(Locale(identifier: "nl_NL"))
    }

    private var cutResultText: String {
        var lines: [String] = [
            "Snijplanner",
            "Max breedte: \(maxWidthCm.formatted(numberFormat)) cm",
            ""
        ]

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
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TintKingHeader(
                        title: "Rolcalculator",
                        subtitle: "Snijplanner en foliecalculator in één scherm.",
                        icon: "ruler"
                    )

                    Picker("Calculator", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .cut {
                        cutPlannerInput
                    } else {
                        foilCalculatorInput
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 620)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Resultaat")
                        .font(.title.bold())

                    if mode == .cut {
                        cutPlannerResult
                    } else {
                        foilCalculatorResult
                    }

                    Spacer()
                }
                .padding(24)
            }
            .frame(minWidth: 360, idealWidth: 430)
        }
    }

    private var cutPlannerInput: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Max breedte").font(.headline)

                HStack {
                    Text("Max breedte")
                    Spacer()
                    AppNumberField(placeholder: "152", value: $maxWidthCm)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("cm")
                }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 12) {
                Text("Maten & aantallen").font(.headline)

                ForEach($cutLines) { $line in
                    let index = cutLines.firstIndex(where: { $0.id == line.id }) ?? 0
                    HStack(spacing: 12) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)

                        AppNumberField(placeholder: "Breedte", value: $line.widthCm)
                            .frame(width: 120)

                        Text("cm")

                        Stepper(value: $line.quantity, in: 1...999) {
                            Text("\(line.quantity)x")
                                .frame(minWidth: 50, alignment: .leading)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            cutLines.removeAll { $0.id == line.id }
                            if cutLines.isEmpty {
                                cutLines = [CutPlannerLine(widthCm: 0, quantity: 1)]
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    cutLines.append(CutPlannerLine(widthCm: 0, quantity: 1))
                } label: {
                    Label("Regel toevoegen", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    maxWidthCm = 152
                    cutLines = [CutPlannerLine(widthCm: 0, quantity: 1)]
                } label: {
                    Label("Alles resetten", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
            .cardStyle()
        }
    }

    private var cutPlannerResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Metric(title: "Gebruikt", value: "\(usedWidthCm.formatted(numberFormat)) cm")
                Metric(title: "Resterend", value: "\(remainingWidthCm.formatted(numberFormat)) cm")

                if remainingWidthCm < 0 {
                    Label(
                        "Je zit \(abs(remainingWidthCm).formatted(numberFormat)) cm over de maximale breedte.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            .cardStyle()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cutResultText, forType: .string)
            } label: {
                Label("Kopieer snij-resultaat", systemImage: "doc.on.doc")
            }
        }
    }

    private var foilCalculatorInput: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Folie calculator").font(.headline)

                HStack {
                    Text("Rolbreedte")
                    Spacer()
                    AppNumberField(placeholder: "152", value: $rollWidthCm)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    Text("cm")
                }

                HStack {
                    Text("Lengte per rol")
                    Spacer()
                    AppNumberField(placeholder: "25", value: $rollLengthM)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
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
                    .frame(width: 100)
                    Text("%")
                }
            }
            .cardStyle()

            HStack {
                Button {
                    rollWidthCm = 152
                    rollLengthM = 25
                    rollCount = 1
                    wastePercent = 10
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }

                Spacer()
            }
        }
    }

    private var foilCalculatorResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Metric(
                    title: "Strekkende meters zonder snijverlies",
                    value: "\(baseLinearMeters.formatted(numberFormat)) m"
                )
                Metric(
                    title: "Strekkende meters incl. snijverlies",
                    value: "\(linearMetersWithWaste.formatted(numberFormat)) m"
                )
                Metric(
                    title: "Oppervlak incl. snijverlies",
                    value: "\(areaWithWaste.formatted(numberFormat)) m²"
                )
            }
            .cardStyle()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(foilResultText, forType: .string)
            } label: {
                Label("Kopieer folie-resultaat", systemImage: "doc.on.doc")
            }

            Text("Tip: als je een rol splitst in meerdere kleine rollen, vul je bij 'Aantal rollen' het aantal deelrollen in en bij 'Lengte per rol' de lengte van één deelrol.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
