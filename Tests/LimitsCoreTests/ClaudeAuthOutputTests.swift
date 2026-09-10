import XCTest
@testable import LimitsCore

final class ClaudeAuthOutputTests: XCTestCase {
    func testReadsOfficialBrowserLinkWithTerminalFormatting() {
        let output = "Open this URL:\n\u{1b}[36mhttps://claude.ai/oauth/authorize?client_id=fixture&state=test\u{1b}[0m\n"
        XCTAssertEqual(ClaudeAuthOutput.authorizationURL(in: output)?.host, "claude.ai")
        XCTAssertEqual(ClaudeAuthOutput.authorizationURL(in: output)?.query, "client_id=fixture&state=test")
    }
    func testRejectsOtherDomainsAndSignInPages() {
        XCTAssertNil(ClaudeAuthOutput.authorizationURL(in: "https://claude.ai.attacker.invalid/oauth/authorize?state=test"))
        XCTAssertNil(ClaudeAuthOutput.authorizationURL(in: "https://attacker.invalid/oauth/authorize?state=test"))
        XCTAssertNil(ClaudeAuthOutput.authorizationURL(in: "https://claude.ai/login"))
        XCTAssertNil(ClaudeAuthOutput.authorizationURL(in: "http://claude.ai/oauth/authorize?state=test"))
    }
}
