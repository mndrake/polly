import EventKit
import Foundation

/// Looks up who was invited to the meeting being recorded, so Claude can
/// match separated voices to real names.
enum CalendarAttendees {
    /// Names of the invitees of the calendar event happening at `date`
    /// (excluding the user), or an empty list if there is none or access is denied.
    static func names(at date: Date) async -> [String] {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        default:
            return []
        }

        let window = store.predicateForEvents(
            withStart: date.addingTimeInterval(-4 * 3600),
            end: date.addingTimeInterval(4 * 3600),
            calendars: nil
        )
        // Events in progress (or starting within 15 minutes) that have invitees,
        // closest start time first.
        let candidates = store.events(matching: window)
            .filter { !$0.isAllDay && ($0.attendees?.isEmpty == false) }
            .filter { $0.startDate <= date.addingTimeInterval(15 * 60) && $0.endDate >= date }
            .sorted { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        guard let event = candidates.first else { return [] }

        var names: [String] = []
        for attendee in event.attendees ?? [] where !attendee.isCurrentUser {
            let name = attendee.name?.trimmingCharacters(in: .whitespaces)
            let email = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            let label = (name?.isEmpty == false ? name : nil) ?? (email.isEmpty ? nil : email)
            if let label, !names.contains(label) { names.append(label) }
        }
        return names
    }
}
