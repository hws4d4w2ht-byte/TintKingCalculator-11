import Foundation
import EventKit

/// Eén regel in de "Herinneringen"-sectie op Home: de gegevens uit een
/// EKReminder die de UI nodig heeft, plus de onderliggende EKReminder zelf om
/// 'm te kunnen afvinken.
struct ReminderItem: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
    let isOverdue: Bool
    let listTitle: String
    fileprivate let reminder: EKReminder
}

/// Haalt openstaande herinneringen op uit de Herinneringen-app (via
/// EventKit) voor de "Herinneringen"-sectie op het Home-tabblad, en laat ze
/// vanuit TintKing Calculator direct afvinken. Nieuwe herinneringen maak je
/// nog in de Herinneringen-app zelf. Alleen op de Mac.
@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var isLoading = false

    private let store = EKEventStore()

    /// Vraagt zo nodig toegang en haalt daarna de openstaande herinneringen op.
    /// Wordt aangeroepen zodra het Home-tabblad verschijnt.
    func start() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        switch authorizationStatus {
        case .fullAccess:
            refresh()
        case .notDetermined:
            requestAccess()
        default:
            break
        }
    }

    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
                if granted {
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard authorizationStatus == .fullAccess else { return }
        isLoading = true
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        _ = store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let mapped = (reminders ?? []).map { reminder -> ReminderItem in
                    let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Naamloze herinnering",
                        dueDate: dueDate,
                        isOverdue: (dueDate ?? .distantFuture) < now,
                        listTitle: reminder.calendar?.title ?? "",
                        reminder: reminder
                    )
                }
                self.items = mapped.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
                self.isLoading = false
            }
        }
    }

    /// Markeert een herinnering als voltooid in de Herinneringen-app en
    /// verwijdert 'm meteen uit de lijst hier, zonder op een volledige
    /// herlaadbeurt te hoeven wachten.
    func complete(_ item: ReminderItem) {
        item.reminder.isCompleted = true
        try? store.save(item.reminder, commit: true)
        items.removeAll { $0.id == item.id }
    }
}
