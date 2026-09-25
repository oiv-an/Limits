import Foundation
import Security
import LimitsCore

enum ClaudeSavedConnection {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pro.ivol.Limits")
    static let file = ClaudeSessionFile(url: directory.appendingPathComponent("claude-session.json"))

    static func removeObsoleteFiles() {
        for name in ["claude-touch-id.json", "touch-id-state.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// One-time import, only if the original login already grants access without a prompt.
    static func importExisting() throws -> ClaudeSession? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let session = ClaudeSession.legacy(data) { return session }
        SecKeychainSetUserInteractionAllowed(false)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials", kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { return nil }
        let reference = item as! SecKeychainItem
        var keychain: SecKeychain?, state: SecKeychainStatus = 0
        guard SecKeychainItemCopyKeychain(reference, &keychain) == errSecSuccess, let keychain,
              SecKeychainGetStatus(keychain, &state) == errSecSuccess,
              state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else {
            throw UsageError.unavailable("Подключение Claude пока недоступно. Повторим автоматически после входа в Mac.")
        }
        var access: SecAccess?, list: CFArray?
        guard SecKeychainItemCopyAccess(reference, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &list) == errSecSuccess else { return nil }
        let trusted = (list as? [SecACL] ?? []).contains { acl in
            guard (SecACLCopyAuthorizations(acl) as? [String] ?? []).contains(kSecACLAuthorizationDecrypt as String) else { return false }
            var apps: CFArray?, label: CFString?, selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &label, &selector) == errSecSuccess else { return false }
            guard let apps else { return true }
            return (apps as? [SecTrustedApplication] ?? []).contains { app in
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data else { return false }
                return String(data: data as Data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) == "/usr/bin/security"
            }
        }
        guard trusted else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel(); try? output.fileHandleForReading.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 65_536 else { return nil }
        return ClaudeSession.legacy(data)
    }
}
