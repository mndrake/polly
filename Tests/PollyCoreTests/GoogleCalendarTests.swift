import XCTest
@testable import PollyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SHA256Tests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testKnownVectors() {
        XCTAssertEqual(hex(SHA256.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(SHA256.hash(Data(repeating: 0x61, count: 1000))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        // RFC 7636 Appendix B.
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = GoogleOAuth.PKCE.generate()
        XCTAssertEqual(generated.verifier.count, 86)
        XCTAssertFalse(generated.verifier.contains("="))
    }
}

final class GoogleOAuthTests: XCTestCase {
    private let client = GoogleOAuth.Client(clientID: " 123-abc.apps.googleusercontent.com ", clientSecret: "GOCSPX-secret")

    func testAuthorizationURL() throws {
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(client: client, redirectURI: "http://127.0.0.1:53682", state: "xyz", pkce: pkce)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(value("client_id"), "123-abc.apps.googleusercontent.com", "client ID is trimmed")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:53682")
        XCTAssertEqual(value("scope"), "openid email https://www.googleapis.com/auth/calendar.events.readonly")
        XCTAssertEqual(value("code_challenge"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("state"), "xyz")
    }

    func testTokenRequestIsFormEncoded() throws {
        let pkce = GoogleOAuth.PKCE(verifier: "v")
        let request = GoogleOAuth.tokenRequest(client: client, code: "4/0Ab+c d", pkce: pkce, redirectURI: "http://127.0.0.1:1")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("code=4%2F0Ab%2Bc%20d"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=v"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1"))
    }

    func testParseTokens() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let ok = try GoogleOAuth.parseTokens(status: 200, data: Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","scope":"s","token_type":"Bearer"}"#.utf8), now: now)
        XCTAssertEqual(ok.accessToken, "ya29.x")
        XCTAssertEqual(ok.refreshToken, "1//r")
        XCTAssertEqual(ok.expiresAt, now.addingTimeInterval(3599))
        XCTAssertTrue(ok.isValid(at: now))
        XCTAssertFalse(ok.isValid(at: now.addingTimeInterval(3550)), "treated as expired a minute early")

        XCTAssertThrowsError(try GoogleOAuth.parseTokens(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))) { error in
            XCTAssertEqual(error as? GoogleOAuth.OAuthError, .server(status: 400, error: "invalid_grant", description: "Token has been expired or revoked."))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Connect Google Calendar again") ?? false)
        }
    }

    func testEmailFromIDToken() throws {
        // header.payload.signature with payload {"email":"me@acme.com","sub":"1"} (base64url, no padding)
        let payload = Base64URL.encode(Data(#"{"email":"me@acme.com","sub":"1"}"#.utf8))
        let body = #"{"access_token":"a","expires_in":3600,"id_token":"eyJhbGciOiJSUzI1NiJ9.\#(payload).sig"}"#
        let tokens = try GoogleOAuth.parseTokens(status: 200, data: Data(body.utf8))
        XCTAssertEqual(tokens.email, "me@acme.com")
    }

    func testParseRedirect() {
        let ok = GoogleOAuth.parseRedirect(requestLine: "GET /?state=xyz&code=4/0AbC&scope=https://www.googleapis.com/auth/calendar.events.readonly HTTP/1.1", expectedState: "xyz")
        XCTAssertEqual(try ok?.get(), "4/0AbC")

        if case .failure(.stateMismatch)? = GoogleOAuth.parseRedirect(requestLine: "GET /?state=evil&code=c HTTP/1.1", expectedState: "xyz") {} else {
            XCTFail("state must match")
        }
        if case .failure(.denied("access_denied"))? = GoogleOAuth.parseRedirect(requestLine: "GET /?error=access_denied&state=xyz HTTP/1.1", expectedState: "xyz") {} else {
            XCTFail("denial is reported")
        }
        XCTAssertNil(GoogleOAuth.parseRedirect(requestLine: "GET /favicon.ico HTTP/1.1", expectedState: "xyz"))
        XCTAssertNil(GoogleOAuth.parseRedirect(requestLine: "garbage", expectedState: "xyz"))
    }
}

final class GoogleCalendarTests: XCTestCase {
    private let sample = """
    {"items":[
      {"summary":"All hands","status":"confirmed","start":{"date":"2026-10-02"},"end":{"date":"2026-10-03"},
       "attendees":[{"email":"everyone@acme.com"}]},
      {"summary":"Cancelled sync","status":"cancelled","start":{"dateTime":"2026-10-02T10:00:00-07:00"},"end":{"dateTime":"2026-10-02T10:30:00-07:00"}},
      {"summary":"Q4 planning","status":"confirmed",
       "start":{"dateTime":"2026-10-02T10:00:00-07:00"},"end":{"dateTime":"2026-10-02T11:00:00-07:00"},
       "attendees":[
         {"email":"me@acme.com","self":true,"responseStatus":"accepted"},
         {"email":"dana.lee@acme.com","displayName":"Dana Lee","responseStatus":"accepted"},
         {"email":"raj_patel@acme.com","responseStatus":"needsAction"},
         {"email":"bob@acme.com","displayName":"Bob","responseStatus":"declined"},
         {"email":"c_188@resource.calendar.google.com","displayName":"Room 4","resource":true}
       ]},
      {"summary":"Solo focus time","status":"confirmed","start":{"dateTime":"2026-10-02T10:05:00-07:00"},"end":{"dateTime":"2026-10-02T12:00:00-07:00"}}
    ]}
    """

    func testParseAndPickTheMeetingInProgress() throws {
        let events = try GoogleCalendarAPI.parseEvents(Data(sample.utf8))
        XCTAssertEqual(events.map(\.title), ["All hands", "Q4 planning", "Solo focus time"], "cancelled events are dropped")
        XCTAssertTrue(events[0].isAllDay)

        let tenOhTwo = ISO8601DateFormatter().date(from: "2026-10-02T17:02:00Z")!
        let best = CalendarMatching.best(events, at: tenOhTwo)
        XCTAssertEqual(best?.title, "Q4 planning", "skips all-day and events without other people")
        XCTAssertEqual(best?.participantNames, ["Dana Lee", "Raj Patel"], "no self, rooms or declines; names from emails")
    }

    func testStartingSoonCountsButNotLongAfterEnd() throws {
        let events = try GoogleCalendarAPI.parseEvents(Data(sample.utf8))
        let early = ISO8601DateFormatter().date(from: "2026-10-02T16:50:00Z")! // 9:50 local
        XCTAssertEqual(CalendarMatching.best(events, at: early)?.title, "Q4 planning")
        let late = ISO8601DateFormatter().date(from: "2026-10-02T18:30:00Z")!
        XCTAssertNil(CalendarMatching.best(events, at: late))
    }

    func testEventsRequest() throws {
        let request = GoogleCalendarAPI.eventsRequest(accessToken: "ya29.t", around: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer ya29.t")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/primary/events?"))
        XCTAssertTrue(url.contains("singleEvents=true"))
        XCTAssertTrue(url.contains("timeMin=1969-12-31T20:00:00Z"))
    }

    func testAttendeeDisplayNames() {
        XCTAssertEqual(CalendarEvent.Attendee(name: nil, email: "jean-luc.picard@x.com").displayName, "Jean Luc Picard")
        XCTAssertEqual(CalendarEvent.Attendee(name: "  ", email: "a@x.com").displayName, "A")
        XCTAssertNil(CalendarEvent.Attendee(name: nil, email: nil).displayName)
    }
}
