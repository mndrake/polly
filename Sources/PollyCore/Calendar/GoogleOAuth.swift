import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth 2.0 for installed apps, as Google documents for desktop clients:
/// the browser signs in and redirects to a loopback address
/// (http://127.0.0.1:<port>) that Polly listens on, with PKCE (S256).
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// Read-only access to calendar events (to find the meeting's invitees and title).
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    /// Calendar access plus the account's email address (to show which account is connected).
    public static let scopes = "openid email \(calendarScope)"

    public struct Client: Sendable, Equatable {
        public var clientID: String
        /// Google issues a secret for desktop clients too; for installed apps
        /// it isn't treated as confidential.
        public var clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    }

    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = Base64URL.encode(SHA256.hash(Data(verifier.utf8)))
        }

        /// 64 random bytes → 86-character verifier (RFC 7636 allows 43–128).
        public static func generate() -> PKCE {
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return PKCE(verifier: Base64URL.encode(Data(bytes)))
        }
    }

    public static func randomState() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public static func authorizationURL(client: Client, redirectURI: String, state: String, pkce: PKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Offline access + consent so Google returns a refresh token.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    public static func tokenRequest(client: Client, code: String, pkce: PKCE, redirectURI: String) -> URLRequest {
        formRequest(tokenEndpoint, [
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
    }

    public static func refreshRequest(client: Client, refreshToken: String) -> URLRequest {
        formRequest(tokenEndpoint, [
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        formRequest(revokeEndpoint, ["token": token])
    }

    public struct Tokens: Sendable, Equatable {
        public var accessToken: String
        public var expiresAt: Date
        /// Only returned on the first exchange (and when consent is re-granted).
        public var refreshToken: String?
        public var scope: String?
        public var idToken: String?

        /// The signed-in account's email, from the ID token. (Read for display
        /// only; the token came straight from Google over TLS.)
        public var email: String? {
            guard let idToken else { return nil }
            let parts = idToken.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while payload.count % 4 != 0 { payload += "=" }
            guard let data = Data(base64Encoded: payload),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return json["email"] as? String
        }

        public func isValid(at date: Date = Date()) -> Bool { expiresAt.timeIntervalSince(date) > 60 }
    }

    public enum OAuthError: Error, Equatable, LocalizedError {
        case denied(String)
        case stateMismatch
        case invalidResponse(String)
        case server(status: Int, error: String, description: String?)
        case notConfigured
        case notConnected

        public var errorDescription: String? {
            switch self {
            case let .denied(reason): return "Google sign-in was cancelled (\(reason))."
            case .stateMismatch: return "Google sign-in failed a security check. Please try again."
            case let .invalidResponse(detail): return "Unexpected response from Google: \(detail)"
            case let .server(status, error, description):
                if error == "invalid_grant" { return "Google access expired or was revoked. Connect Google Calendar again in Settings." }
                return "Google returned \(status) \(error)\(description.map { ": \($0)" } ?? "")"
            case .notConfigured: return "Add your Google OAuth client ID and secret in Settings first."
            case .notConnected: return "Google Calendar isn't connected."
            }
        }
    }

    public static func parseTokens(status: Int, data: Data, now: Date = Date()) throws -> Tokens {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw OAuthError.server(
                status: status,
                error: json?["error"] as? String ?? "error",
                description: json?["error_description"] as? String
            )
        }
        guard let access = json?["access_token"] as? String else {
            throw OAuthError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let expiresIn = (json?["expires_in"] as? Double) ?? Double(json?["expires_in"] as? Int ?? 3600)
        return Tokens(
            accessToken: access,
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshToken: json?["refresh_token"] as? String,
            scope: json?["scope"] as? String,
            idToken: json?["id_token"] as? String
        )
    }

    /// Parses the browser's redirect to the loopback server, e.g.
    /// "GET /?state=abc&code=4/0Ab…&scope=… HTTP/1.1". Returns nil for
    /// unrelated requests such as /favicon.ico.
    public static func parseRedirect(requestLine: String, expectedState: String) -> Result<String, OAuthError>? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              let items = components.queryItems, !items.isEmpty
        else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { return .failure(.denied(error)) }
        guard let code = value("code") else { return nil }
        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        return .success(code)
    }

    private static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal SHA-256 (FIPS 180-4) so PKCE works without CryptoKit (and on Linux).
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var digest = Data()
        for value in h { for shift in stride(from: 24, through: 0, by: -8) { digest.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
        return digest
    }
}
