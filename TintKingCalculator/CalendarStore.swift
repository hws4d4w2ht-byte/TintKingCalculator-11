import Foundation
import EventKit

/// Eén regel in de "Agenda"-sectie op Home: de gegevens uit een EKEvent die
/// de UI nodig heeft.
struct CalendarEventItem: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String?
}

/// Haalt de afspraken van vandaag op uit de Agenda-app (via EventKit) voor
/// de "Agenda"-sectie op het Home-tabblad. Nieuwe afspraken maak je nog in
/// de Agenda-app zelf — dit is puur een overzicht, zodat je in één oogopslag
/// ziet wat er vandaag op de planning staat naast de rest van Home.
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var items: [CalendarEventItem] = []
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()

    /// Vraagt zo nodig toegang en haalt daarna de afspraken van vandaag op.
    /// Wordt aangeroepen zodra het Home-tabblad verschijnt.
    func start() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
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
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if granted {
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard authorizationStatus == .fullAccess else { return }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
        items = events
            .map { event in
                CalendarEventItem(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Naamloze afspraak",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar?.title ?? "",
                    location: event.location
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }
}
