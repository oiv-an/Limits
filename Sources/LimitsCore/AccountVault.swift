import CryptoKit
import Darwin
import Foundation
import Security

public enum AccountProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex
    public var title: String { self == .claude ? "Claude" : "Codex" }
}

/// One subscription account. Secrets live only inside the encrypted vault file.
public struct StoredAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: AccountProvider
    public var customName: String?
    public var email: String?
    public var claudeSession: ClaudeSession?
    /// Raw Codex `auth.json`, written to a temporary CODEX_HOME only for the duration of a request.
    public var codexAuth: Data?
    public var snapshot: UsageSnapshot?
    public var addedAt: Date

    public init(
        id: UUID = UUID(), provider: AccountProvider, customName: String? = nil,
        email: String? = nil, claudeSession: ClaudeSession? = nil, codexAuth: Data? = nil,
        snapshot: UsageSnapshot? = nil, addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.customName = customName
        self.email = email
        self.claudeSession = claudeSession
        self.codexAuth = codexAuth
        self.snapshot = snapshot
        self.addedAt = addedAt
    }

    public var displayName: String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return email ?? provider.title
    }
}

public protocol VaultKeyStore: Sendable {
    /// Returns nil when no key exists yet.
    func read() throws -> Data?
    func create() throws -> Data
}

/// A random 256-bit key in the login keychain of this Mac. The item ACL trusts only the
/// application that created it (by its code signature), it is never synchronised to iCloud,
/// so a copied vault cannot be decrypted on another Mac or by another program.
public struct KeychainVaultKey: VaultKeyStore {
    let service = "pro.ivol.Limits.vault"
    let account = "accounts-vault-key"
    public init() {}

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read() throws -> Data? {
        var result: CFTypeRef?
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled || status == errSecAuthFailed {
            // Builds without a stable signature (ad-hoc) ask once after each update.
            throw UsageError.unavailable(
                "Разрешите Limits доступ к ключу хранилища: в запросе связки ключей введите пароль Mac и нажмите «Всегда разрешать»."
            )
        }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw UsageError.unavailable(
                "Хранилище аккаунтов пока недоступно (связка ключей \(status)). Повторим автоматически."
            )
        }
        return data
    }

    public func create() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw UsageError.unavailable("Не удалось создать ключ хранилища аккаунтов.")
        }
        let data = Data(bytes)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Limits — ключ хранилища аккаунтов"
        item[kSecAttrSynchronizable] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw UsageError.unavailable(
                "Не удалось сохранить ключ хранилища аккаунтов (\(status)).")
        }
        return data
    }
}

/// All accounts in one AES-256-GCM encrypted file (mode 600, directory 700).
public final class AccountVault: @unchecked Sendable {
    private struct Contents: Codable {
        var version = 1
        var accounts: [StoredAccount] = []
    }
    private static let magic = Data("LMV1".utf8)

    public static let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pro.ivol.Limits")
    public static let standard = AccountVault(
        url: directory.appendingPathComponent("accounts.vault"), keyStore: KeychainVaultKey())

    public let url: URL
    private let keyStore: any VaultKeyStore
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var contents = Contents()
    /// True when an unreadable vault from another Mac was discarded on open.
    public private(set) var wasReset = false

    public init(url: URL, keyStore: any VaultKeyStore) {
        self.url = url
        self.keyStore = keyStore
    }

    public var isOpen: Bool { lock.withLock { key != nil } }

    /// Loads the vault once. Throws only for temporary problems; never overwrites data it could not read
    /// because of a temporary keychain error.
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }
        guard key == nil else { return }
        let fileData = try readFile()
        if let stored = try keyStore.read() {
            let candidate = SymmetricKey(data: stored)
            if let fileData {
                if let decoded = try? decrypt(fileData, key: candidate) {
                    contents = decoded
                } else {
                    // Wrong key or damaged file: the accounts must simply be connected again.
                    try? FileManager.default.removeItem(at: url)
                    contents = Contents()
                    wasReset = true
                }
            }
            key = candidate
        } else {
            if fileData != nil {
                // Vault copied from another Mac or the key was removed: unreadable by design.
                try? FileManager.default.removeItem(at: url)
                wasReset = true
            }
            contents = Contents()
            key = SymmetricKey(data: try keyStore.create())
        }
    }

    public var accounts: [StoredAccount] { lock.withLock { contents.accounts } }

    public func account(_ id: UUID) -> StoredAccount? {
        lock.withLock { contents.accounts.first { $0.id == id } }
    }

    public func add(_ account: StoredAccount) throws {
        try mutate { $0.accounts.append(account) }
    }

    /// Applies a change to an existing account. Returns false if it was removed meanwhile.
    @discardableResult
    public func update(_ id: UUID, _ change: (inout StoredAccount) -> Void) throws -> Bool {
        var found = false
        try mutate { contents in
            guard let index = contents.accounts.firstIndex(where: { $0.id == id }) else { return }
            change(&contents.accounts[index])
            found = true
        }
        return found
    }

    public func remove(_ id: UUID) throws {
        try mutate { $0.accounts.removeAll { $0.id == id } }
    }

    private func mutate(_ change: (inout Contents) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let key else {
            throw UsageError.unavailable("Хранилище аккаунтов ещё не открыто. Повторите позже.")
        }
        var updated = contents
        change(&updated)
        try write(encrypt(updated, key: key))
        contents = updated
    }

    private func encrypt(_ contents: Contents, key: SymmetricKey) throws -> Data {
        let plain = try JSONEncoder().encode(contents)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw UsageError.unavailable("Не удалось зашифровать хранилище аккаунтов.")
        }
        return Self.magic + sealed
    }

    private func decrypt(_ data: Data, key: SymmetricKey) throws -> Contents {
        guard data.starts(with: Self.magic) else { throw UsageError.invalidResponse }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
        return try JSONDecoder().decode(Contents.self, from: AES.GCM.open(box, using: key))
    }

    private func readFile() throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw UsageError.unavailable("Не удалось прочитать хранилище аккаунтов.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == geteuid(), info.st_size <= 16_777_216
        else { throw UsageError.invalidResponse }
        return try handle.readToEnd() ?? Data()
    }

    private func write(_ data: Data) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".vault-\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw UsageError.unavailable("Не удалось сохранить хранилище аккаунтов.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? manager.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else {
            throw UsageError.unavailable("Не удалось сохранить хранилище аккаунтов.")
        }
    }
}

/// Session storage of one Claude account inside the vault.
public struct VaultClaudeStore: ClaudeSessionStore {
    public let vault: AccountVault
    public let id: UUID
    public init(vault: AccountVault, id: UUID) {
        self.vault = vault
        self.id = id
    }
    public func load() throws -> ClaudeSession? { vault.account(id)?.claudeSession }
    public func save(_ session: ClaudeSession) throws {
        try vault.update(id) { account in
            account.claudeSession = session
            if account.email == nil { account.email = session.email }
        }
    }
}
