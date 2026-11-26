import Foundation
import LimitsCore

/// Plain-file storage of version 1.2. Read once for migration into the encrypted vault, then deleted.
enum ClaudeSavedConnection {
    static let directory = AccountVault.directory
    static let file = ClaudeSessionFile(
        url: directory.appendingPathComponent("claude-session.json"))

    static func removeObsoleteFiles() {
        for name in ["claude-touch-id.json", "touch-id-state.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
