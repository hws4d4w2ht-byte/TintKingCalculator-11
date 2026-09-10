import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Toetsenbord-vriendelijk gedrag voor schermen met tekst-/getalvelden op de telefoon:
/// naar beneden swipen tijdens scrollen sluit het toetsenbord, en er verschijnt een
/// "Gereed"-knop boven het toetsenbord om 'm ook handmatig weg te tikken. Op macOS
/// bestaat dit probleem niet (geen schermvullend toetsenbord), dus daar doet dit niets.
extension View {
    @ViewBuilder
    func withKeyboardDismiss() -> some View {
        #if os(iOS)
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Gereed") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        #else
        self
        #endif
    }
}
