import Foundation

public struct ClaudeSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]
    public var requiresSignIn: Bool

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                scopes: [String] = ["user:profile"], requiresSignIn: Bool = false) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.scopes = scopes; self.requiresSignIn = requiresSignIn
    }

    public func needsRefresh(at now: Date = Date()) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) <= 60 } ?? false
    }

    public static func legacy(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return Self(accessToken: token, refreshToken: oauth["refreshToken"] as? String,
                    expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                    scopes: oauth["scopes"] as? [String] ?? ["user:profile", "user:inference"])
    }

    public static func tokenResponse(_ data: Data, replacing old: Self? = nil, now: Date = Date()) throws -> Self {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["access_token"] as? String, !token.isEmpty,
              let seconds = body["expires_in"] as? Double, seconds.isFinite, seconds > 0 else {
            throw UsageError.invalidResponse
        }
        return Self(accessToken: token, refreshToken: body["refresh_token"] as? String ?? old?.refreshToken,
                    expiresAt: now.addingTimeInterval(seconds),
                    scopes: (body["scope"] as? String)?.split(separator: " ").map(String.init)
                        ?? old?.scopes ?? ["user:profile"])
    }
}

public protocol ClaudeTransport: Sendable {
    func usage(accessToken: String) async throws -> UsageSnapshot
    func refresh(_ session: ClaudeSession) async throws -> ClaudeSession
}

public actor ClaudeSessionService {
    private let file: ClaudeSessionFile
    private let transport: any ClaudeTransport
    private let importExisting: @Sendable () throws -> ClaudeSession?
    private var session: ClaudeSession?
    private var loaded = false
    private var generation = 0
    private var inFlight: Task<UsageSnapshot, Error>?
    private var retryUntil: Date?

    public init(file: ClaudeSessionFile, transport: any ClaudeTransport = ClaudeHTTPClient(),
                importExisting: @escaping @Sendable () throws -> ClaudeSession? = { nil }) {
        self.file = file; self.transport = transport; self.importExisting = importExisting
    }

    public func accept(_ newSession: ClaudeSession) throws {
        try file.save(newSession)
        session = newSession; loaded = true; generation += 1
        inFlight?.cancel(); inFlight = nil; retryUntil = nil
    }

    public func fetch() async throws -> UsageSnapshot {
        if let inFlight { return try await inFlight.value }
        if let retryUntil, retryUntil > Date() { throw UsageError.retryLater(seconds: retryUntil.timeIntervalSinceNow) }
        let revision = generation
        let task = Task { try await self.fetchOnce(revision: revision) }
        inFlight = task
        defer { if generation == revision { inFlight = nil } }
        do { return try await task.value }
        catch {
            guard generation == revision else { throw CancellationError() }
            if case UsageError.retryLater(let seconds) = error { retryUntil = Date().addingTimeInterval(seconds) }
            if case UsageError.signIn = error, var current = session {
                current.requiresSignIn = true; session = current
                try? file.save(current)
            }
            throw error
        }
    }

    private func fetchOnce(revision: Int) async throws -> UsageSnapshot {
        if !loaded {
            session = try file.load()
            if session == nil, let imported = try importExisting() {
                try file.save(imported); session = imported
            }
            loaded = true
        }
        guard var current = session, !current.requiresSignIn else {
            throw UsageError.signIn("Подключите Claude один раз через браузер. Дальше лимиты обновляются автоматически.")
        }
        var refreshed = false
        if current.needsRefresh(), current.refreshToken != nil {
            current = try await refresh(current, revision: revision); refreshed = true
        }
        do {
            let result = try await transport.usage(accessToken: current.accessToken)
            try check(revision)
            return result
        } catch UsageError.signIn where !refreshed && current.refreshToken != nil {
            current = try await refresh(current, revision: revision)
            let result = try await transport.usage(accessToken: current.accessToken)
            try check(revision)
            return result
        }
    }

    private func refresh(_ current: ClaudeSession, revision: Int) async throws -> ClaudeSession {
        let renewed = try await transport.refresh(current)
        try check(revision)
        // Persist a rotated refresh token before the next request, even if usage is temporarily unavailable.
        try file.save(renewed); session = renewed
        return renewed
    }

    private func check(_ revision: Int) throws {
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
    }
}
