import EventKit
import Foundation

/// Best-effort meeting title from the local calendar. Nothing is written back,
/// and no calendar data leaves the machine.
enum CalendarLookup {

    private static let store = EKEventStore()

    static func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    /// Title of an event overlapping `date`, preferring one that looks like a
    /// call (has attendees or a conferencing URL) and starts nearest to now.
    static func currentEventTitle(at date: Date = Date(), tolerance: TimeInterval = 5 * 60) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return nil }

        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-tolerance),
                                                 end: date.addingTimeInterval(tolerance),
                                                 calendars: calendars)
        let candidates = store.events(matching: predicate).filter { event in
            guard !event.isAllDay, let title = event.title, !title.isEmpty else { return false }
            return event.status != .canceled
        }
        guard !candidates.isEmpty else { return nil }

        func looksLikeACall(_ event: EKEvent) -> Bool {
            if event.hasAttendees { return true }
            let haystack = [event.location, event.notes, event.url?.absoluteString]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return ["zoom.us", "meet.google", "teams.microsoft", "webex", "whereby", "slack"]
                .contains { haystack.contains($0) }
        }

        let sorted = candidates.sorted { lhs, rhs in
            if looksLikeACall(lhs) != looksLikeACall(rhs) { return looksLikeACall(lhs) }
            return abs(lhs.startDate.timeIntervalSince(date)) < abs(rhs.startDate.timeIntervalSince(date))
        }
        return sorted.first?.title
    }
}
