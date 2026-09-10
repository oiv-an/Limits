import Foundation

public enum ClaudeAuthOutput {
    public static func authorizationURL(in output: String) -> URL? {
        let cleaned = output.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"https://claude\.ai/oauth/authorize\?[^\s\u001B]+"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let range = Range(match.range, in: cleaned), let url = URL(string: String(cleaned[range])),
              url.scheme == "https", url.host == "claude.ai", url.path == "/oauth/authorize",
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
