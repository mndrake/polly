import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A calendar event, from Google Calendar or Apple Calendar.
public struct CalendarEvent: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public var name: String?
        public var email: String?
        public var isSelf: Bool
        /// Meeting rooms and other resources.
        public var isResource: Bool
        public var declined: Bool

        public init(name: String?, email: String?, isSelf: Bool = false, isResource: Bool = false, declined: Bool = false) {
            self.name = name
            self.email = email
            self.isSelf = isSelf
            self.isResource = isResource
            self.declined = declined
        }

        /// "Dana Lee", or a name derived from the address ("dana.lee@x.com" → "Dana Lee").
        public var displayName: String? {
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            guard let email, let local = email.split(separator: "@").first, !local.isEmpty else { return nil }
            let words = local.split(whereSeparator: { ".-_+".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.isEmpty ? email : words.joined(separator: " ")
        }
    }

    public var title: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [Attendee]

    public init(title: String?, start: Date, end: Date, isAllDay: Bool = false, attendees: [Attendee]) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
    }

    /// Invitees other than the user, rooms and people who declined.
    public var participantNames: [String] {
        var names: [String] = []
        for attendee in attendees where !attendee.isSelf && !attendee.isResource && !attendee.declined {
            if let name = attendee.displayName, !names.contains(name) { names.append(name) }
        }
        return names
    }
}

public enum CalendarMatching {
    /// The event being recorded: in progress at `date` or starting within
    /// `lookahead`, with other participants, closest start time first.
    public static func best(_ events: [CalendarEvent], at date: Date, lookahead: TimeInterval = 15 * 60) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay && !$0.participantNames.isEmpty }
            .filter { $0.start <= date.addingTimeInterval(lookahead) && $0.end >= date }
            .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
}

/// Google Calendar API v3 (primary calendar, read-only).
public enum GoogleCalendarAPI {
    public static func eventsRequest(accessToken: String, around date: Date, window: TimeInterval = 4 * 3600) -> URLRequest {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: date.addingTimeInterval(-window))),
            URLQueryItem(name: "timeMax", value: formatter.string(from: date.addingTimeInterval(window))),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "fields", value: "items(summary,status,start,end,attendees(email,displayName,self,resource,responseStatus))"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        return request
    }

    public static func parseEvents(_ data: Data) throws -> [CalendarEvent] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GoogleOAuth.OAuthError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard item["status"] as? String != "cancelled",
                  let (start, startAllDay) = parseTime(item["start"]),
                  let (end, _) = parseTime(item["end"])
            else { return nil }
            let attendees = (item["attendees"] as? [[String: Any]] ?? []).map { a in
                CalendarEvent.Attendee(
                    name: a["displayName"] as? String,
                    email: a["email"] as? String,
                    isSelf: a["self"] as? Bool ?? false,
                    isResource: a["resource"] as? Bool ?? false,
                    declined: a["responseStatus"] as? String == "declined"
                )
            }
            return CalendarEvent(title: item["summary"] as? String, start: start, end: end, isAllDay: startAllDay, attendees: attendees)
        }
    }

    /// `{"dateTime": "2026-10-02T10:00:00-07:00"}` or `{"date": "2026-10-02"}` (all-day).
    static func parseTime(_ value: Any?) -> (Date, Bool)? {
        guard let object = value as? [String: Any] else { return nil }
        if let dateTime = object["dateTime"] as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateTime) { return (date, false) }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateTime).map { ($0, false) }
        }
        if let day = object["date"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: day).map { ($0, true) }
        }
        return nil
    }
}
