import SwiftUI

@main
struct TintKingCalculatorApp_iOS: App {
    init() {
        CloudSyncMigration.resetLocalSyncBookkeepingIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            MobileContentView()
        }
    }
}
