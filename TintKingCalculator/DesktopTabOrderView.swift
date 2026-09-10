import SwiftUI

/// Scherm waarin je de volgorde van de tabbladen in de Mac-tabbalk zelf kunt
/// aanpassen door ze te verslepen. Bereikbaar vanaf Home via het
/// pijltjes-icoon rechtsboven — net als op mobiel.
///
/// Werkt met een eigen kopie (`draftOrder`) die pas bij het verlaten van dit
/// scherm wordt doorgevoerd naar de store — zie de toelichting in
/// DesktopTabOrderStore.swift voor waarom dat nodig is.
struct DesktopTabOrderView: View {
    @ObservedObject var store: DesktopTabOrderStore
    @State private var draftOrder: [AppTab] = []

    var body: some View {
        List {
            Section {
                ForEach(draftOrder, id: \.self) { tab in
                    HStack(spacing: 12) {
                        Image(systemName: tab.desktopTabImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text(tab.desktopTabTitle)
                    }
                }
                .onMove { source, destination in
                    draftOrder.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                Text("Sleep een tabblad naar de gewenste plek om de volgorde in de tabbalk aan te passen.")
            }
        }
        .navigationTitle("Volgorde aanpassen")
        .toolbar {
            ToolbarItem {
                Button("Standaard") {
                    draftOrder = DesktopTabOrderStore.defaultOrder
                }
            }
        }
        .frame(minWidth: 320, minHeight: 420)
        .onAppear {
            draftOrder = store.order
        }
        .onDisappear {
            store.commit(draftOrder)
        }
    }
}
