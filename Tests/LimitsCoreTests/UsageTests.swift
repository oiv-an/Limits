import XCTest
@testable import LimitsCore

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testWeeklyPrimaryIsNotMislabeledFiveHours() throws {
        let snapshot = try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":84,"windowDurationMins":10080,"resetsAt":2000},"secondary":null}}"#), now: now)
        let window = try XCTUnwrap(snapshot.headline(at: now))
        XCTAssertEqual(window.title, "Неделя")
        XCTAssertEqual(window.remaining, 16)
    }
    func testMultiBucketWinsAndKeepsSparkIndependent() throws {
        let snapshot = try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex_bengalfox":{"limitName":"Spark","primary":{"usedPercent":0,"windowDurationMins":300}},"codex":{"primary":{"usedPercent":85,"windowDurationMins":10080}}}}"#), now: now)
        XCTAssertEqual(snapshot.groups.first?.id, "codex")
        XCTAssertEqual(snapshot.headline(at: now)?.remaining, 15)
        XCTAssertEqual(snapshot.headline(groupID: "codex_bengalfox", at: now)?.remaining, 100)
    }
    func testMostConstrainedPeriodIsHeadline() throws {
        let snapshot = try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":93,"windowDurationMins":10080}}}"#), now: now)
        XCTAssertEqual(snapshot.headline(at: now)?.remaining, 7)
    }
    func testMissingPercentDoesNotBecomeOneHundred() throws {
        XCTAssertThrowsError(try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":null},"secondary":null}}"#)))
        XCTAssertThrowsError(try UsageParser.claude(data(#"{"five_hour":null,"seven_day":{"resets_at":null}}"#), source: "test"))
    }
    func testBooleanIsNotAUsagePercentage() throws {
        XCTAssertThrowsError(try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":true}}}"#)))
    }
    func testClaudePercentScaleAndModelWindows() throws {
        let snapshot = try UsageParser.claude(data(#"{"five_hour":{"utilization":0.5,"resets_at":"2027-01-01T12:00:00.000Z"},"seven_day":{"utilization":22.0,"resets_at":"2027-01-05T12:00:00Z"},"seven_day_sonnet":{"utilization":90,"resets_at":null},"extra_usage":{"is_enabled":true,"utilization":99}}"#), source: "test", now: now)
        XCTAssertEqual(snapshot.groups.count, 2)
        XCTAssertEqual(snapshot.groups[0].windows[0].remaining, 99.5)
        XCTAssertNotNil(snapshot.groups[0].windows[0].resetsAt)
        XCTAssertNotNil(snapshot.groups[0].windows[1].resetsAt)
        XCTAssertEqual(snapshot.headline(at: now)?.remaining, 78)
        XCTAssertEqual(snapshot.groups[1].title, "Sonnet")
    }
    func testExpiredWindowCannotClaimNewQuota() {
        let window = UsageWindow(id: "w", title: "5 ч", usedPercent: 100, resetsAt: now)
        let snapshot = UsageSnapshot(provider: "codex", groups: [.init(id: "codex", title: "Codex", windows: [window])], source: "test")
        XCTAssertNil(snapshot.headline(at: now))
        XCTAssertEqual(window.remaining, 0)
    }
    func testClampsOutOfRangeAndDoesNotRoundTinyQuotaToZero() {
        XCTAssertEqual(UsageWindow(id: "a", title: "a", usedPercent: 101).remaining, 0)
        XCTAssertEqual(UsageWindow(id: "a", title: "a", usedPercent: -5).remaining, 100)
        XCTAssertEqual(UsageWindow(id: "a", title: "a", usedPercent: 99.5).percentageText, "<1%")
    }
    func testCacheBecomesStaleAndRoundTrips() throws {
        let snapshot = UsageSnapshot(provider: "claude", groups: [], fetchedAt: now, source: "test")
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(500), interval: 300))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(800), interval: 300))
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testMalformedJSONFails() {
        XCTAssertThrowsError(try UsageParser.codex(data("not json")))
        XCTAssertThrowsError(try UsageParser.claude(data("[]"), source: "test"))
    }
}
