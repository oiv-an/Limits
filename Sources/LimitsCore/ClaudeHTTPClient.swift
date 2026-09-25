import Foundation

private final class NoCredentialRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ClaudeHTTPClient: ClaudeTransport {
    // Public OAuth client used by the official Claude subscription sign-in flow; this is not a secret.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public init() {}

    public func usage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        return try UsageParser.claude(await send(request), source: "Claude")
    }

    public func refresh(_ session: ClaudeSession) async throws -> ClaudeSession {
        guard let token = session.refreshToken, !token.isEmpty else { throw UsageError.signIn("Войдите в Claude через браузер.") }
        var body = ["grant_type": "refresh_token", "refresh_token": token, "client_id": Self.clientID]
        if !session.scopes.isEmpty { body["scope"] = session.scopes.joined(separator: " ") }
        return try ClaudeSession.tokenResponse(await tokenRequest(body), replacing: session)
    }

    public func exchange(code: String, verifier: String, state: String, redirectURI: String) async throws -> ClaudeSession {
        try ClaudeSession.tokenResponse(await tokenRequest(["grant_type": "authorization_code", "code": code,
            "client_id": Self.clientID, "redirect_uri": redirectURI, "code_verifier": verifier, "state": state]))
    }

    private func tokenRequest(_ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func send(_ original: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoCredentialRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = original
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Limits/1.2.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.signIn("Claude отклонил сохранённый вход. Подключите аккаунт через браузер.")
        case 400:
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if error == "invalid_grant" { throw UsageError.signIn("Вход в Claude отозван или истёк. Подключите аккаунт через браузер.") }
            throw UsageError.unavailable("Claude не смог обновить подключение. Повторим автоматически.")
        case 429:
            throw UsageError.retryLater(seconds: max(300, min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900, 86400)))
        default: throw UsageError.unavailable("Claude временно недоступен (\(http.statusCode)).")
        }
    }
}
