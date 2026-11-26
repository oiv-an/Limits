import AppKit
import LimitsCore
import ServiceManagement
import SwiftUI

struct ProviderState {
    var snapshot: UsageSnapshot?
    var message: String?
    var loading = false
    var needsLogin = false
    var retryAt: Date?
    func stale(interval: TimeInterval) -> Bool {
        message != nil || (snapshot?.isStale(interval: interval) ?? false)
    }
}

/// What the UI shows for one subscription account. Secrets stay in the vault.
struct AccountState: Identifiable {
    let id: UUID
    let provider: AccountProvider
    var name: String
    var email: String?
    var addedAt: Date
    var state = ProviderState()
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var accounts: [AccountState] = []
    @Published var floating: Bool {
        didSet {
            UserDefaults.standard.set(floating, forKey: "floating")
            onFloatingChanged?()
        }
    }
    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            scheduleTimer()
        }
    }
    @Published var codexGroup: String {
        didSet { UserDefaults.standard.set(codexGroup, forKey: "codexGroup") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settingsMessage: String?
    /// Problems with the encrypted account storage itself (keychain locked, reset on a new Mac).
    @Published var vaultMessage: String?
    @Published var codexAuthenticating = false
    @Published var codexLoginMessage: String?
    let connection = ClaudeConnection()
    let vault = AccountVault.standard
    var onFloatingChanged: (() -> Void)?
    private var codexAuthTask: Task<Data, Error>?
    private var claudeServices: [UUID: ClaudeSessionService] = [:]
    private var revisions: [UUID: Int] = [:]
    private var timer: Timer?
    private var legacyCacheURL: URL {
        AccountVault.directory.appendingPathComponent("usage-cache.json")
    }

    init() {
        floating = UserDefaults.standard.bool(forKey: "floating")
        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = [120.0, 300.0, 600.0].contains(savedInterval) ? savedInterval : 300
        codexGroup = UserDefaults.standard.string(forKey: "codexGroup") ?? "codex"
        CodexClient.removeTemporaryHomes()
        connection.onSession = { [weak self] session, target in
            guard let self else { return }
            try await self.acceptClaude(session, target: target)
        }
        openVault()
    }

    // MARK: Vault

    private func openVault() {
        guard !vault.isOpen else { return }
        do {
            try vault.open()
            vaultMessage =
                vault.wasReset
                ? "Сохранённые аккаунты зашифрованы ключом другого Mac или прежней установки. Подключите аккаунты заново."
                : nil
            migrateLegacyFiles()
            accounts = vault.accounts.map { stored in
                var account = AccountState(
                    id: stored.id, provider: stored.provider, name: stored.displayName,
                    email: stored.email, addedAt: stored.addedAt)
                account.state.snapshot = stored.snapshot?.forDisplay()
                if account.state.snapshot != nil {
                    account.state.message = "Сохранённые данные. Обновляем…"
                }
                return account
            }
            sortAccounts()
        } catch {
            vaultMessage =
                (error as? UsageError)?.localizedDescription
                ?? "Хранилище аккаунтов пока недоступно. Повторим автоматически."
        }
    }

    /// Moves the single Claude login of version 1.2 into the vault and removes plain files.
    private func migrateLegacyFiles() {
        let manager = FileManager.default
        if let session = try? ClaudeSavedConnection.file.load(),
            !vault.accounts.contains(where: { $0.provider == .claude })
        {
            var cachedClaude: UsageSnapshot?
            if let data = try? Data(contentsOf: legacyCacheURL),
                let cached = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data)
            {
                cachedClaude = cached["claude"]
            }
            try? vault.add(
                StoredAccount(
                    provider: .claude, email: session.email, claudeSession: session,
                    snapshot: cachedClaude))
        }
        if vault.accounts.contains(where: { $0.provider == .claude })
            || (try? ClaudeSavedConnection.file.load()) == nil
        {
            try? manager.removeItem(at: ClaudeSavedConnection.file.url)
        }
        try? manager.removeItem(at: legacyCacheURL)
        ClaudeSavedConnection.removeObsoleteFiles()
    }

    private func sortAccounts() {
        accounts.sort { a, b in
            if a.provider != b.provider { return a.provider == .codex }
            return a.addedAt < b.addedAt
        }
    }

    private func index(_ id: UUID) -> Int? { accounts.firstIndex { $0.id == id } }

    func account(_ id: UUID) -> AccountState? { accounts.first { $0.id == id } }

    /// Number shown next to the icon when several accounts of one provider exist.
    func badge(for account: AccountState) -> String? {
        let same = accounts.filter { $0.provider == account.provider }
        guard same.count > 1, let position = same.firstIndex(where: { $0.id == account.id }) else {
            return nil
        }
        return "\(position + 1)"
    }

    private func setState(_ id: UUID, _ change: (inout ProviderState) -> Void) {
        guard let i = index(id) else { return }
        change(&accounts[i].state)
    }

    private func saveSnapshot(_ id: UUID) {
        let snapshot = account(id)?.state.snapshot
        _ = try? vault.update(id) { $0.snapshot = snapshot }
    }

    /// Finds the account for a fresh login: the requested one, the same email, or a new account.
    private func resolveAccount(provider: AccountProvider, email: String?, target: UUID?) throws
        -> UUID
    {
        if let target, account(target) != nil { return target }
        if let email,
            let existing = accounts.first(where: {
                $0.provider == provider && $0.email?.lowercased() == email.lowercased()
            })
        {
            return existing.id
        }
        let stored = StoredAccount(provider: provider, email: email)
        try vault.add(stored)
        accounts.append(
            AccountState(
                id: stored.id, provider: provider, name: stored.displayName, email: email,
                addedAt: stored.addedAt))
        sortAccounts()
        return stored.id
    }

    private func updateEmail(_ id: UUID, _ email: String?) {
        guard let email, let i = index(id), accounts[i].email != email else { return }
        _ = try? vault.update(id) { $0.email = email }
        accounts[i].email = email
        if let stored = vault.account(id) { accounts[i].name = stored.displayName }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? vault.update(id) { $0.customName = trimmed.isEmpty ? nil : trimmed }
        if let i = index(id), let stored = vault.account(id) {
            accounts[i].name = stored.displayName
        }
    }

    func remove(_ id: UUID) {
        do {
            try vault.remove(id)
        } catch {
            settingsMessage = "Не удалось удалить аккаунт. Повторите попытку."
            return
        }
        revisions[id, default: 0] += 1
        claudeServices[id] = nil
        accounts.removeAll { $0.id == id }
    }

    // MARK: Refresh

    func start() {
        refresh()
        scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var anyLoading: Bool { accounts.contains { $0.state.loading } }

    func refresh() {
        openVault()
        for account in accounts { refresh(account.id) }
    }

    func refresh(_ id: UUID, force: Bool = false) {
        guard let account = account(id) else { return }
        switch account.provider {
        case .codex: refreshCodex(id)
        case .claude: refreshClaude(id, force: force)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(30, interval * 0.1)
    }

    private func refreshCodex(_ id: UUID) {
        guard let current = account(id), !current.state.loading else { return }
        guard let auth = vault.account(id)?.codexAuth else {
            setState(id) {
                $0.needsLogin = true
                $0.message = "Войдите в этот аккаунт Codex."
            }
            return
        }
        setState(id) { $0.loading = true }
        let revision = revisions[id, default: 0]
        let vault = self.vault
        Task {
            do {
                let reading = try await Task.detached(priority: .utility) {
                    try CodexClient.fetch(auth: auth) { rotated in
                        // Save rotated tokens unless the account was re-logged in meanwhile.
                        _ = try? vault.update(id) { account in
                            if account.codexAuth == auth { account.codexAuth = rotated }
                        }
                    }
                }.value
                guard revision == revisions[id, default: 0] else { return }
                setState(id) { $0 = ProviderState(snapshot: reading.snapshot.forDisplay()) }
                updateEmail(id, reading.email)
                saveSnapshot(id)
            } catch {
                guard revision == revisions[id, default: 0] else { return }
                setState(id) { $0 = Self.applying(error, to: $0) }
                saveSnapshot(id)
            }
        }
    }

    private func claudeService(_ id: UUID) -> ClaudeSessionService {
        if let service = claudeServices[id] { return service }
        let service = ClaudeSessionService(file: VaultClaudeStore(vault: vault, id: id))
        claudeServices[id] = service
        return service
    }

    func refreshClaude(_ id: UUID, force: Bool = false) {
        guard let current = account(id), !current.state.loading else { return }
        if !force, let retryAt = current.state.retryAt, retryAt > Date() { return }
        setState(id) { $0.loading = true }
        let revision = revisions[id, default: 0]
        let service = claudeService(id)
        Task {
            do {
                let snapshot = try await service.fetch()
                guard revision == revisions[id, default: 0] else { return }
                setState(id) { $0 = ProviderState(snapshot: snapshot) }
                saveSnapshot(id)
                if account(id)?.email == nil,
                    let token = vault.account(id)?.claudeSession?.accessToken
                {
                    updateEmail(id, await ClaudeHTTPClient().profileEmail(accessToken: token))
                }
            } catch {
                guard revision == revisions[id, default: 0] else { return }
                setState(id) { $0 = Self.applying(error, to: $0) }
                saveSnapshot(id)
            }
        }
    }

    // MARK: Login

    /// Browser login finished; `target` is the account being re-connected, nil for a new one.
    private func acceptClaude(_ session: ClaudeSession, target: UUID?) async throws {
        openVault()
        var session = session
        if session.email == nil {
            session.email = await ClaudeHTTPClient().profileEmail(accessToken: session.accessToken)
        }
        let id = try resolveAccount(provider: .claude, email: session.email, target: target)
        revisions[id, default: 0] += 1
        let revision = revisions[id, default: 0]
        let service = claudeService(id)
        try await service.accept(session)
        updateEmail(id, session.email)
        setState(id) { $0 = ProviderState(loading: true) }
        do {
            let snapshot = try await service.fetch()
            guard revision == revisions[id, default: 0] else { return }
            setState(id) { $0 = ProviderState(snapshot: snapshot) }
            saveSnapshot(id)
        } catch {
            guard revision == revisions[id, default: 0] else { throw error }
            setState(id) { $0 = Self.applying(error, to: $0) }
            saveSnapshot(id)
            throw error
        }
    }

    func addClaude() { connection.showLogin(target: nil, name: nil) }

    func reconnect(_ id: UUID) {
        guard let account = account(id) else { return }
        switch account.provider {
        case .claude: connection.showLogin(target: id, name: account.name)
        case .codex: loginCodex(target: id)
        }
    }

    func loginCodex(target: UUID?) {
        guard !codexAuthenticating else { return }
        openVault()
        codexAuthenticating = true
        codexLoginMessage =
            "Завершите вход в браузере. Если браузер сам выбирает прежний аккаунт ChatGPT, выйдите из него в браузере и повторите."
        let worker = Task.detached(priority: .userInitiated) { try CodexClient.login() }
        codexAuthTask = worker
        Task {
            do {
                let auth = try await worker.value
                let email = CodexClient.email(fromAuth: auth)
                let id = try resolveAccount(provider: .codex, email: email, target: target)
                try vault.update(id) { $0.codexAuth = auth }
                updateEmail(id, email)
                revisions[id, default: 0] += 1
                setState(id) { $0 = ProviderState() }
                codexLoginMessage = nil
                codexAuthenticating = false
                codexAuthTask = nil
                refreshCodex(id)
            } catch {
                codexLoginMessage =
                    error is CancellationError
                    ? nil
                    : (error as? UsageError)?.localizedDescription
                        ?? "Не удалось войти в Codex. Повторите попытку."
                codexAuthenticating = false
                codexAuthTask = nil
            }
        }
    }

    func cancelCodexAuthentication() {
        codexAuthTask?.cancel()
    }

    private static func applying(_ error: Error, to previous: ProviderState) -> ProviderState {
        var state = previous
        state.loading = false
        state.message =
            (error as? UsageError)?.localizedDescription
            ?? "Не удалось обновить данные. Проверьте интернет."
        if case UsageError.signIn = error {
            state.needsLogin = true
            // A signed-out account must not keep showing an old percentage.
            state.snapshot = nil
        }
        if case UsageError.retryLater(let seconds) = error {
            state.retryAt = Date().addingTimeInterval(seconds)
        }
        return state
    }

    // MARK: Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage =
                SMAppService.mainApp.status == .requiresApproval
                ? "Разрешите автозапуск в настройках macOS → Объекты входа." : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage = "Для автозапуска перенесите Limits в «Программы» и повторите."
        }
    }

    func title(for account: AccountState) -> String {
        let groupID = account.provider == .codex ? codexGroup : nil
        guard let headline = account.state.snapshot?.headline(groupID: groupID) else {
            return account.state.loading && account.state.snapshot == nil ? "…" : "—"
        }
        return headline.percentageText + (account.state.stale(interval: interval) ? "·" : "")
    }
}
