import SwiftUI

/// Invulveld voor decimale getallen met een eigen tekstbuffer, zodat je nooit
/// eerst een "0" hoeft weg te halen voordat je je eigen waarde kunt intypen —
/// standaard SwiftUI-gedrag bij `TextField(value:format:)` dwingt dat namelijk
/// wel af. Gebruikt door alle calculators, op zowel Mac als mobiel.
///
/// Werkt verder net als een gewone TextField: modifiers als `.frame(width:)`,
/// `.multilineTextAlignment(...)` etc. kun je er gewoon achteraan hangen.
struct AppNumberField: View {
    var placeholder: String = ""
    @Binding var value: Double
    var decimals: ClosedRange<Int> = 0...2

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused($isFocused)
            .onAppear { text = Self.format(value, decimals: decimals) }
            .onChange(of: value) { _, newValue in
                if !isFocused { text = Self.format(newValue, decimals: decimals) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: text) { _, newText in
                if let parsed = Self.parse(newText) {
                    value = parsed
                }
            }
    }

    private func commit() {
        if let parsed = Self.parse(text) {
            value = parsed
            text = Self.format(parsed, decimals: decimals)
        } else {
            text = Self.format(value, decimals: decimals)
        }
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func format(_ value: Double, decimals: ClosedRange<Int>) -> String {
        if value == 0 { return "" }
        if decimals.upperBound == 0 {
            return String(Int(value.rounded()))
        }
        if decimals.lowerBound == decimals.upperBound {
            return String(format: "%.\(decimals.upperBound)f", value)
        }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        var s = String(format: "%.\(decimals.upperBound)f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
