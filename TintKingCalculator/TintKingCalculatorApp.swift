import SwiftUI

@main
struct TintKingCalculatorApp: App {
    init() {
        CloudSyncMigration.resetLocalSyncBookkeepingIfNeeded()
        // Zet, indien nodig, de teruggevonden Supabase-back-up eenmalig terug
        // naar iCloud (zie CloudSync.swift, onderaan) — alleen op de Mac-app,
        // zodat dit maar op één plek gebeurt.
        Task { await SupabaseBackupRestore.restoreIfNeeded() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1180, height: 820)
    }
}
