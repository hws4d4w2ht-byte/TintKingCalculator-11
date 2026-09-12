import SwiftUI

@main
struct TintKingCalculatorApp: App {
    init() {
        CloudSyncMigration.resetLocalSyncBookkeepingIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1180, height: 820)
    }
}
