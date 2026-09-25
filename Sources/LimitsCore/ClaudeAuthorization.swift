import Foundation
import CryptoKit

public struct ClaudeAuthorization: Sendable {
    public let verifier: String
    public let state: String
    public let redirectURI: String

    public init(port: UInt16) {
        verifier = Self.random(); state = Self.random()
        redirectURI = "http://localhost:\(port)/callback"
    }
    public var url: URL {
        var url = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
        url.queryItems = [URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeHTTPClient.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "user:profile user:inference"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)]
        return url.url!
    }
    public func code(fromCallback target: String) -> String? {
        guard target.hasPrefix("/callback?"), target.utf8.count < 8192,
              let url = URLComponents(string: "http://localhost" + target), url.path == "/callback" else { return nil }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }, codes = items.filter { $0.name == "code" }
        guard states.count == 1, states.first?.value == state, codes.count == 1,
              let code = codes.first?.value, !code.isEmpty, code.count < 4096 else { return nil }
        return code
    }
    public func code(fromPaste text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == state, !parts[0].isEmpty, parts[0].count < 4096 else { return nil }
        return String(parts[0])
    }
    private static func random() -> String { base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
