import EventKit
import Foundation
import PollyCore

/// Finds the calendar event for the meeting being recorded — Google Calendar
/// first (if connected), then the calendars in macOS Calendar — so Claude
/// can match voices to real names and the meeting gets its real title.
@MainActor
enum MeetingCalendar {
    static func event(at date: Date, google: GoogleCalendarService) async -> CalendarEvent? {
        if google.isConnected {
            do {
                if let event = CalendarMatching.best(try await google.events(around: date), at: date) { return event }
            } catch {
                PollyLog.info("Google Calendar lookup failed: \(error.localizedDescription)")
            }
        }
        return await AppleCalendar.event(at: date)
    }
}

/// macOS Calendar (EventKit). Includes any Google, Exchange or iCloud
/// accounts added in System Settings → Internet Accounts.
enum AppleCalendar {
    static func event(at date: Date) async -> CalendarEvent? {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        default:
            return nil
        }

        let window = store.predicateForEvents(
            withStart: date.addingTimeInterval(-4 * 3600),
            end: date.addingTimeInterval(4 * 3600),
            calendars: nil
        )
        let events = store.events(matching: window).map { event in
            CalendarEvent(
                title: event.title,
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                attendees: (event.attendees ?? []).map { attendee in
                    CalendarEvent.Attendee(
                        name: attendee.name,
                        email: attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                        isSelf: attendee.isCurrentUser,
                        isResource: attendee.participantType == .room || attendee.participantType == .resource,
                        declined: attendee.participantStatus == .declined
                    )
                }
            )
        }
        return CalendarMatching.best(events, at: date)
    }
}
