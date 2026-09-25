import XCTest
import CryptoKit
@testable import LimitsCore

private actor StubClaude: ClaudeTransport {
    var reads = 0
    var renewals = 0
    var tokens: [String] = []
    var rejectOldToken: Bool
    var renewalError: UsageError?
    let renewed = ClaudeSession(accessToken: "fixture-new", refreshToken: "fixture-rotated", expiresAt: Date().addingTimeInterval(3600))
    init(rejectOldToken: Bool = false, renewalError: UsageError? = nil) {
        self.rejectOldToken = rejectOldToken; self.renewalError = renewalError
    }
    func usage(accessToken: String) async throws -> UsageSnapshot {
        reads += 1; tokens.append(accessToken)
        try await Task.sleep(for: .milliseconds(25))
        if rejectOldToken && accessToken == "fixture-old" { throw UsageError.signIn("expired") }
        return UsageSnapshot(provider: "claude", groups: [UsageGroup(id: "claude", title: "Claude",
            windows: [UsageWindow(id: "five_hour", title: "5 ч", usedPercent: 9)])], source: "fixture")
    }
    func refresh(_ session: ClaudeSession) async throws -> ClaudeSession {
        renewals += 1
        try await Task.sleep(for: .milliseconds(25))
        if let renewalError { throw renewalError }
        return renewed
    }
    func counts() -> (Int, Int) { (reads, renewals) }
}

final class ClaudeSessionTests: XCTestCase {
    private var directory: URL!
    private var file: ClaudeSessionFile!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("limits-session-test-\(UUID().uuidString)")
        file = ClaudeSessionFile(url: directory.appendingPathComponent("session.json"))
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }

    func testSavedLoginSurvivesRelaunchWithoutImportOrPrompt() async throws {
        let session = ClaudeSession(accessToken: "fixture-current", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600))
        try file.save(session)
        let transport = StubClaude()
        let first = ClaudeSessionService(file: file, transport: transport, importExisting: { XCTFail("Saved session must not read Keychain"); return nil })
        _ = try await first.fetch()
        let restarted = ClaudeSessionService(file: file, transport: transport, importExisting: { XCTFail("Relaunch must not read Keychain"); return nil })
        _ = try await restarted.fetch()
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }

    func testExpiredSessionRefreshesAndPersistsRotatedToken() async throws {
        try file.save(ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast))
        let transport = StubClaude()
        let service = ClaudeSessionService(file: file, transport: transport)
        _ = try await service.fetch()
        XCTAssertEqual(try file.load()?.refreshToken, "fixture-rotated")
        let restarted = ClaudeSessionService(file: file, transport: transport)
        _ = try await restarted.fetch()
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 1)
        let tokens = await transport.tokens
        XCTAssertEqual(tokens, ["fixture-new", "fixture-new"])
    }

    func testServerExpiryRefreshesOnceEvenWhenLocalExpiryIsLater() async throws {
        try file.save(ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantFuture))
        let transport = StubClaude(rejectOldToken: true)
        _ = try await ClaudeSessionService(file: file, transport: transport).fetch()
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 1)
    }

    func testConcurrentRefreshRequestsShareOneRenewal() async throws {
        try file.save(ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast))
        let transport = StubClaude()
        let service = ClaudeSessionService(file: file, transport: transport)
        async let first = service.fetch()
        async let second = service.fetch()
        _ = try await (first, second)
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testOfflineRefreshKeepsSavedSession() async throws {
        let original = ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast)
        try file.save(original)
        do {
            _ = try await ClaudeSessionService(file: file, transport: StubClaude(renewalError: .unavailable("offline"))).fetch()
            XCTFail("Expected offline error")
        } catch { XCTAssertEqual(error as? UsageError, .unavailable("offline")) }
        XCTAssertEqual(try file.load(), original)
    }

    func testRevokedSessionDoesNotRepeatRefreshAfterRelaunch() async throws {
        try file.save(ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast))
        let transport = StubClaude(renewalError: .signIn("revoked"))
        for _ in 0..<2 {
            do { _ = try await ClaudeSessionService(file: file, transport: transport).fetch(); XCTFail("Expected signed out") }
            catch { guard case UsageError.signIn = error else { return XCTFail("Wrong error") } }
        }
        let counts = await transport.counts()
        XCTAssertEqual(counts.1, 1); XCTAssertEqual(try file.load()?.requiresSignIn, true)
    }

    func testSwitchingAccountDiscardsPendingRefresh() async throws {
        try file.save(ClaudeSession(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast))
        let transport = StubClaude()
        let service = ClaudeSessionService(file: file, transport: transport)
        let task = Task { try await service.fetch() }
        while await transport.counts().1 == 0 { await Task.yield() }
        let other = ClaudeSession(accessToken: "fixture-other-account", expiresAt: .distantFuture)
        try await service.accept(other)
        do { _ = try await task.value; XCTFail("Previous account response must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try file.load(), other)
    }

    func testSessionFileIsOwnerOnlyAndRejectsSymlinkReads() throws {
        try file.save(ClaudeSession(accessToken: "fixture-one"))
        try file.save(ClaudeSession(accessToken: "fixture-two"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
        XCTAssertThrowsError(try ClaudeSessionFile(url: link).load())
    }

    func testMigrationPreservesRefreshTokenAndMillisecondExpiry() throws {
        let session = try XCTUnwrap(ClaudeSession.legacy(Data(#"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":1800000000000,"scopes":["user:profile"]}}"#.utf8)))
        XCTAssertEqual(session.expiresAt?.timeIntervalSince1970, 1800000000)
        XCTAssertEqual(session.refreshToken, "fixture-refresh")
        let renewed = try ClaudeSession.tokenResponse(Data(#"{"access_token":"fixture-new","expires_in":3600}"#.utf8), replacing: session, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(renewed.refreshToken, session.refreshToken)
        XCTAssertEqual(renewed.expiresAt?.timeIntervalSince1970, 3700)
    }

    func testBrowserCallbackRequiresCurrentStateAndPKCE() throws {
        let auth = ClaudeAuthorization(port: 49152)
        let params = try XCTUnwrap(URLComponents(url: auth.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(params.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(auth.url.absoluteString.contains(auth.verifier))
        XCTAssertEqual(auth.code(fromCallback: "/callback?code=fixture&state=\(auth.state)"), "fixture")
        XCTAssertNil(auth.code(fromCallback: "/callback?code=fixture&state=wrong"))
        XCTAssertNil(auth.code(fromCallback: "/callback?code=fixture&code=other&state=\(auth.state)"))
        XCTAssertNil(auth.code(fromCallback: "/other?code=fixture&state=\(auth.state)"))
        XCTAssertEqual(auth.code(fromPaste: "fixture#\(auth.state)"), "fixture")
        XCTAssertNil(auth.code(fromPaste: "fixture#wrong"))
    }
}
