import AppKit
import CryptoKit
import LocalAuthentication
import Security
import LimitsCore

enum ClaudeTouchID {
    static var vaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pro.ivol.Limits/claude-touch-id.json")
    }
    static var hasSavedConnection: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }

    @MainActor
    static func authenticate() async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Отмена"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .touchID, SecureEnclave.isAvailable else {
            throw UsageError.locked("Touch ID сейчас недоступен. Разблокируйте Mac и повторите. Limits не будет запрашивать пароль.")
        }
        NSApp.activate(ignoringOtherApps: true)
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Разблокировать подключение Claude для обновления лимитов") else {
                throw UsageError.locked("Подтвердите подключение через Touch ID.")
            }
        } catch {
            context.invalidate()
            throw UsageError.locked("Touch ID не подтверждён. Нажмите «Разблокировать Touch ID», когда будете готовы.")
        }
        // The existing biometric authorization is reused; key operations may never show another prompt.
        context.interactionNotAllowed = true
        return context
    }

    static func read(context: LAContext, importExisting: Bool) throws -> String {
        if hasSavedConnection && !importExisting {
            let envelope = try JSONDecoder().decode(SealedCredential.self, from: Data(contentsOf: vaultURL))
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.wrappedDeviceKey,
                                                                   authenticationContext: context)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            guard let token = String(data: try envelope.open(sharedSecret: secret), encoding: .utf8), !token.isEmpty else {
                throw UsageError.invalidResponse
            }
            return token
        }
        guard let token = try ClaudeCredentialImport.read() else {
            throw UsageError.signIn("Вход Claude не найден. Подключите аккаунт через браузер.")
        }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &error) else {
            if let error { throw error.takeRetainedValue() }
            throw UsageError.invalidResponse
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: control, authenticationContext: context)
        let envelope = try SealedCredential.seal(Data(token.utf8), devicePublicKey: key.publicKey,
                                                wrappedDeviceKey: key.dataRepresentation)
        // Validate the real Secure Enclave round trip before replacing any previous saved connection.
        let restoredKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.wrappedDeviceKey,
                                                                        authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        let restored = try envelope.open(sharedSecret: restoredKey.sharedSecretFromKeyAgreement(with: peer))
        guard restored == Data(token.utf8) else { throw UsageError.invalidResponse }
        try FileManager.default.createDirectory(at: vaultURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(envelope).write(to: vaultURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        return token
    }
}

private enum ClaudeCredentialImport {
    /// Called only after Touch ID, never by a timer. Never changes the Claude Code item's ACL.
    static func read() throws -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = token(in: data) { return token }
        // LAContext alone does not suppress the old macOS keychain's application-trust password dialog.
        SecKeychainSetUserInteractionAllowed(false)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials", kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw importUnavailable }
        let reference = item as! SecKeychainItem
        var keychain: SecKeychain?, keychainStatus: SecKeychainStatus = 0
        guard SecKeychainItemCopyKeychain(reference, &keychain) == errSecSuccess,
              let keychain, SecKeychainGetStatus(keychain, &keychainStatus) == errSecSuccess,
              keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { throw importUnavailable }
        // Claude Code itself uses Apple's security tool. Only use that tool if this exact item already trusts it.
        var access: SecAccess?, aclList: CFArray?
        guard SecKeychainItemCopyAccess(reference, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &aclList) == errSecSuccess else { throw importUnavailable }
        let trusted = (aclList as? [SecACL] ?? []).contains { acl in
            let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard auths.contains(kSecACLAuthorizationDecrypt as String) else { return false }
            var apps: CFArray?, label: CFString?, selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &label, &selector) == errSecSuccess else { return false }
            guard let apps else { return true }
            return (apps as? [SecTrustedApplication] ?? []).contains { app in
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data,
                      let path = String(data: data as Data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters),
                      path == "/usr/bin/security" else { return false }
                return true // /usr/bin/security is protected by macOS System Integrity Protection.
            }
        }
        guard trusted else { throw importUnavailable }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw importUnavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 65_536 else { throw importUnavailable }
        return token(in: data)
    }

    private static var importUnavailable: UsageError {
        .locked("Не удалось перенести подключение без пароля. Разблокируйте Mac и повторите Touch ID; Limits не меняет защиту связки ключей.")
    }
    private static func token(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
