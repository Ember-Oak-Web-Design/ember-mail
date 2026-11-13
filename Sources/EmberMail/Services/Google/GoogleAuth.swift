import AppKit
import CryptoKit
import Foundation
import Network

struct GoogleTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

/// OAuth 2.0 for installed apps: system browser + loopback redirect + PKCE.
actor GoogleAuth {
    static let shared = GoogleAuth()

    static let scopes = [
        "openid", "email", "profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
    ]

    /// Public OAuth client id (safe to ship; kept out of git via LocalConfig). The matching client secret lives only on the Worker,
    /// which performs the token exchange and refresh (see server/tracking-worker).
    static let clientID = LocalConfig.googleClientID
    static let tokenBase = URL(string: LocalConfig.workerBaseURL + "/oauth")!

    struct SignInResult: Sendable {
        var tokens: GoogleTokens
        var email: String
        var name: String
    }

    private var memoryTokens: [UUID: GoogleTokens] = [:]

    // MARK: Sign in

    func signIn() async throws -> SignInResult {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomString(24)

        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
        ]
        let authURL = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let callback = try await server.waitForCallback(timeout: 300)
        let params = Dictionary(uniqueKeysWithValues: (callback.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = params["error"] { throw MailError.authFailed(error) }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.authFailed("Google didn't return an authorization code.")
        }

        let request = try Self.workerRequest("token", ["code": code, "redirect_uri": redirectURI, "code_verifier": verifier])
        let token = try await HTTP.json(TokenResponse.self, request)
        guard let refresh = token.refresh_token else {
            throw MailError.authFailed("Google didn't return a refresh token. Remove Ember Mail's access at myaccount.google.com/permissions and try again.")
        }
        let tokens = GoogleTokens(accessToken: token.access_token, refreshToken: refresh,
                                  expiry: Date().addingTimeInterval(TimeInterval(token.expires_in - 60)))

        var info = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        info.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let user = try await HTTP.json(UserInfo.self, info)
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        return SignInResult(tokens: tokens, email: user.email, name: user.name ?? user.email)
    }

    // MARK: Tokens

    func store(_ tokens: GoogleTokens, for accountID: UUID) {
        memoryTokens[accountID] = tokens
        if let data = try? JSONEncoder().encode(tokens), let json = String(data: data, encoding: .utf8) {
            Keychain.set(json, for: Keychain.googleTokensKey(accountID))
        }
    }

    func forget(_ accountID: UUID) {
        memoryTokens[accountID] = nil
        Keychain.delete(Keychain.googleTokensKey(accountID))
    }

    private func loadTokens(_ accountID: UUID) -> GoogleTokens? {
        if let t = memoryTokens[accountID] { return t }
        guard let json = Keychain.get(Keychain.googleTokensKey(accountID)),
              let t = try? JSONDecoder().decode(GoogleTokens.self, from: Data(json.utf8)) else { return nil }
        memoryTokens[accountID] = t
        return t
    }

    func accessToken(for accountID: UUID) async throws -> String {
        guard var tokens = loadTokens(accountID) else {
            throw MailError.authFailed("Your Google account needs to be connected again (Settings → Accounts).")
        }
        if tokens.expiry > Date() { return tokens.accessToken }
        let request = try Self.workerRequest("refresh", ["refresh_token": tokens.refreshToken])
        let response: TokenResponse
        do {
            response = try await HTTP.json(TokenResponse.self, request)
        } catch {
            throw MailError.authFailed("Google sign-in expired. Reconnect the account in Settings → Accounts. (\(error.localizedDescription))")
        }
        tokens.accessToken = response.access_token
        tokens.expiry = Date().addingTimeInterval(TimeInterval(response.expires_in - 60))
        if let newRefresh = response.refresh_token { tokens.refreshToken = newRefresh }
        store(tokens, for: accountID)
        return tokens.accessToken
    }

    // MARK: Helpers

    private static func workerRequest(_ endpoint: String, _ body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: tokenBase.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int
        var refresh_token: String?
    }

    private struct UserInfo: Decodable {
        var email: String
        var name: String?
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

/// Tiny HTTP server on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.emberoak.mail.oauth")
    private var callbackContinuation: CheckedContinuation<URLComponents, Error>?
    private var pendingResult: Result<URLComponents, Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.fire() { cont.resume(throwing: MailError.network(error.localizedDescription)) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URLComponents {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URLComponents, Error>) in
            queue.async {
                if let pending = self.pendingResult {
                    cont.resume(with: pending)
                    return
                }
                self.callbackContinuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(MailError.timeout))
                }
            }
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count >= 2 ? parts[1] : "/"
            let components = URLComponents(string: "http://127.0.0.1\(path)")
            let isCallback = components?.queryItems?.contains { $0.name == "code" || $0.name == "error" } ?? false

            let body = isCallback
                ? """
                  <html><head><meta charset="utf-8"><title>Ember Mail</title></head>
                  <body style="font-family:-apple-system;display:flex;align-items:center;justify-content:center;height:90vh;background:#faf7f5;color:#2b1d14">
                  <div style="text-align:center"><div style="font-size:48px">✉️</div><h2>You're connected</h2>
                  <p>You can close this tab and return to Ember Mail.</p></div></body></html>
                  """
                : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback, let components {
                self.finish(.success(components))
            }
        }
    }
}
