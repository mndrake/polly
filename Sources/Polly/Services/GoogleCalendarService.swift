import AppKit
import Foundation
import Network
import PollyCore

/// Connects to the user's Google Calendar (read-only) so Polly knows who was
/// invited to the meeting being recorded, and what it's called.
///
/// Uses Google's flow for desktop apps: the browser signs in and redirects
/// to http://127.0.0.1:<port> where Polly is briefly listening. The user
/// provides their own OAuth client (see docs/GOOGLE_CALENDAR.md). The refresh
/// token and client secret are kept in the Keychain.
@MainActor
final class GoogleCalendarService: ObservableObject {
    @Published private(set) var connectedEmail: String?
    @Published private(set) var isConnecting = false
    @Published var lastError: String?

    private var cachedTokens: GoogleOAuth.Tokens?
    private var loopback: LoopbackRedirectServer?

    init() {
        if KeychainStore.read(account: KeychainStore.googleRefreshTokenAccount) != nil {
            let email = AppSettings.defaults.string(forKey: SettingsKey.googleAccountEmail) ?? ""
            connectedEmail = email.isEmpty ? "Google account" : email
        }
    }

    var isConnected: Bool { connectedEmail != nil }

    var client: GoogleOAuth.Client {
        GoogleOAuth.Client(
            clientID: AppSettings.defaults.string(forKey: SettingsKey.googleClientID) ?? "",
            clientSecret: KeychainStore.read(account: KeychainStore.googleClientSecretAccount) ?? ""
        )
    }

    func saveClient(id: String, secret: String) {
        objectWillChange.send()
        lastError = nil
        AppSettings.defaults.set(id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SettingsKey.googleClientID)
        KeychainStore.save(secret, account: KeychainStore.googleClientSecretAccount)
    }

    // MARK: - Connect / disconnect

    func connect() async {
        let client = self.client
        guard client.isConfigured else {
            lastError = GoogleOAuth.OAuthError.notConfigured.localizedDescription
            return
        }
        isConnecting = true
        lastError = nil
        defer {
            isConnecting = false
            loopback?.stop()
            loopback = nil
        }

        do {
            let pkce = GoogleOAuth.PKCE.generate()
            let state = GoogleOAuth.randomState()
            let server = LoopbackRedirectServer(expectedState: state)
            loopback = server
            let port = try await server.start()
            let redirectURI = "http://127.0.0.1:\(port)"

            NSWorkspace.shared.open(GoogleOAuth.authorizationURL(client: client, redirectURI: redirectURI, state: state, pkce: pkce))
            let code = try await server.waitForCode(timeout: 300)
            NSApp.activate(ignoringOtherApps: true)

            let (data, response) = try await URLSession.shared.data(for: GoogleOAuth.tokenRequest(client: client, code: code, pkce: pkce, redirectURI: redirectURI))
            let tokens = try GoogleOAuth.parseTokens(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
            guard let refresh = tokens.refreshToken else {
                throw GoogleOAuth.OAuthError.invalidResponse("Google didn't return a refresh token")
            }
            KeychainStore.save(refresh, account: KeychainStore.googleRefreshTokenAccount)
            cachedTokens = tokens
            let email = tokens.email ?? ""
            AppSettings.defaults.set(email, forKey: SettingsKey.googleAccountEmail)
            connectedEmail = email.isEmpty ? "Google account" : email
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelConnect() {
        loopback?.cancel()
    }

    func disconnect() {
        if let refresh = KeychainStore.read(account: KeychainStore.googleRefreshTokenAccount) {
            let request = GoogleOAuth.revokeRequest(token: refresh)
            Task.detached { _ = try? await URLSession.shared.data(for: request) }
        }
        KeychainStore.save("", account: KeychainStore.googleRefreshTokenAccount)
        AppSettings.defaults.set("", forKey: SettingsKey.googleAccountEmail)
        cachedTokens = nil
        connectedEmail = nil
    }

    // MARK: - Events

    /// Events on the primary calendar within a few hours of `date`.
    func events(around date: Date) async throws -> [CalendarEvent] {
        let token = try await accessToken()
        let (data, response) = try await URLSession.shared.data(for: GoogleCalendarAPI.eventsRequest(accessToken: token, around: date))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { cachedTokens = nil }
            throw GoogleOAuth.OAuthError.server(status: status, error: "calendar", description: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try GoogleCalendarAPI.parseEvents(data)
    }

    private func accessToken() async throws -> String {
        if let cachedTokens, cachedTokens.isValid() { return cachedTokens.accessToken }
        guard let refresh = KeychainStore.read(account: KeychainStore.googleRefreshTokenAccount) else {
            throw GoogleOAuth.OAuthError.notConnected
        }
        let (data, response) = try await URLSession.shared.data(for: GoogleOAuth.refreshRequest(client: client, refreshToken: refresh))
        do {
            let tokens = try GoogleOAuth.parseTokens(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
            cachedTokens = tokens
            return tokens.accessToken
        } catch let error as GoogleOAuth.OAuthError {
            if case .server(_, "invalid_grant", _) = error {
                disconnect() // revoked or expired; the user must connect again
                lastError = error.localizedDescription
            }
            throw error
        }
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that receives Google's redirect.
final class LoopbackRedirectServer {
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var earlyResult: Result<String, Error>?
    private let queue = DispatchQueue(label: "app.polly.oauth-loopback")

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    /// Starts listening on a free port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumed = true
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser redirect and returns the authorization code.
    func waitForCode(timeout: TimeInterval) async throws -> String {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.queue.async { self?.finish(.failure(GoogleOAuth.OAuthError.denied("timed out"))) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.earlyResult {
                    continuation.resume(with: early)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(GoogleOAuth.OAuthError.denied("cancelled"))) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let requestLine = request.components(separatedBy: "\r\n").first ?? ""
            let outcome = GoogleOAuth.parseRedirect(requestLine: requestLine, expectedState: self.expectedState)

            let page: String
            switch outcome {
            case .success?:
                page = "<h2>Polly is connected to Google Calendar.</h2><p>You can close this tab and return to Polly.</p>"
            case let .failure(error)?:
                page = "<h2>Google Calendar wasn't connected.</h2><p>\(error.localizedDescription)</p>"
            case nil:
                page = ""
            }
            let body = outcome == nil ? "" : "<!doctype html><html><head><meta charset=utf-8><title>Polly</title></head><body style=\"font-family:-apple-system;margin:3em\">\(page)</body></html>"
            let status = outcome == nil ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            switch outcome {
            case let .success(code)?: self.finish(.success(code))
            case let .failure(error)?: self.finish(.failure(error))
            case nil: break
            }
        }
    }

    /// Must be called on `queue`.
    private func finish(_ result: Result<String, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else if earlyResult == nil {
            earlyResult = result
        }
    }
}
