import SwiftUI

/// Scherm waarin je de volgorde van de tabbladen onderin de app zelf kunt
/// aanpassen door ze te verslepen aan het handvat rechts. Bereikbaar vanaf
/// Home via het pijltjes-icoon rechtsboven.
struct TabOrderView: View {
    @ObservedObject var store: TabOrderStore

    var body: some View {
        List {
            Section {
                ForEach(store.order, id: \.self) { tab in
                    HStack(spacing: 12) {
                        Image(systemName: tab.mobileTabImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text(tab.mobileTabTitle)
                    }
                }
                .onMove(perform: store.moveTabs)
            } footer: {
                Text("Sleep een tabblad naar de gewenste plek met het handvat rechts.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Volgorde aanpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Standaard") {
                    store.resetToDefault()
                }
            }
        }
    }
}
