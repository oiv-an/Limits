import AppKit
import SwiftUI
import ServiceManagement
import LimitsCore

struct ProviderState {
    var snapshot: UsageSnapshot?
    var message: String?
    var loading = false
    var needsLogin = false
    var requiresUnlock = false
    var retryAt: Date?
    func stale(interval: TimeInterval) -> Bool { message != nil || (snapshot?.isStale(interval: interval) ?? false) }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex = ProviderState()
    @Published var claude = ProviderState()
    @Published var floating: Bool { didSet { UserDefaults.standard.set(floating, forKey: "floating"); onFloatingChanged?() } }
    @Published var interval: Double { didSet { UserDefaults.standard.set(interval, forKey: "refreshInterval"); scheduleTimer() } }
    @Published var codexGroup: String { didSet { UserDefaults.standard.set(codexGroup, forKey: "codexGroup") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settingsMessage: String?
    let connection = ClaudeConnection()
    var onFloatingChanged: (() -> Void)?
    private var timer: Timer?
    private var claudeRevision = 0
    private let cacheURL: URL

    init() {
        floating = UserDefaults.standard.bool(forKey: "floating")
        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = [120.0, 300.0, 600.0].contains(savedInterval) ? savedInterval : 300
        codexGroup = UserDefaults.standard.string(forKey: "codexGroup") ?? "codex"
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pro.ivol.Limits/usage-cache.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data) {
            codex.snapshot = cached["codex"]; claude.snapshot = cached["claude"]
            if codex.snapshot != nil { codex.message = "Сохранённые данные. Обновляем…" }
            if claude.snapshot != nil { claude.message = "Сохранённые данные. Обновляем…" }
        }
        connection.onConnected = { [weak self] snapshot in
            self?.claudeRevision += 1
            self?.claude = ProviderState(snapshot: snapshot)
            self?.saveCache()
        }
        connection.onError = { [weak self] error in
            guard let self else { return }
            self.claudeRevision += 1
            self.claude = self.applying(error, to: self.claude)
            self.saveCache()
        }
    }

    func start() {
        refresh(); scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() { refreshCodex(); refreshClaude() }
    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(30, interval * 0.1)
    }
    func refreshCodex() {
        guard !codex.loading else { return }
        codex.loading = true
        Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) { try CodexClient.fetch() }.value
                codex = ProviderState(snapshot: snapshot)
                saveCache()
            } catch { codex = applying(error, to: codex); saveCache() }
        }
    }
    func refreshClaude(force: Bool = false) {
        guard !claude.loading else { return }
        if !force, let retryAt = claude.retryAt, retryAt > Date() { return }
        claude.loading = true
        let revision = claudeRevision
        Task {
            do {
                let snapshot = try await connection.fetch()
                guard revision == claudeRevision else { return }
                claude = ProviderState(snapshot: snapshot)
                saveCache()
            } catch {
                guard revision == claudeRevision else { return }
                claude = applying(error, to: claude); saveCache()
            }
        }
    }
    private func applying(_ error: Error, to previous: ProviderState) -> ProviderState {
        var state = previous
        state.loading = false
        state.message = (error as? UsageError)?.localizedDescription ?? "Не удалось обновить данные. Проверьте интернет."
        if case UsageError.signIn = error {
            state.needsLogin = true
            state.requiresUnlock = false
            // A signed-out account must not inherit another account's cached percentage.
            state.snapshot = nil
        }
        if case UsageError.locked = error { state.requiresUnlock = true; state.needsLogin = false }
        if case UsageError.retryLater(let seconds) = error { state.retryAt = Date().addingTimeInterval(seconds) }
        return state
    }
    private func saveCache() {
        var snapshots: [String: UsageSnapshot] = [:]
        snapshots["codex"] = codex.snapshot; snapshots["claude"] = claude.snapshot
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* Cache is optional. Live readings remain available. */ }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "Разрешите автозапуск в настройках macOS → Объекты входа." : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage = "Для автозапуска перенесите Limits в «Программы» и повторите."
        }
    }
    func title(for state: ProviderState, groupID: String? = nil) -> String {
        guard let headline = state.snapshot?.headline(groupID: groupID) else { return state.loading && state.snapshot == nil ? "…" : "—" }
        return headline.percentageText + (state.stale(interval: interval) ? "·" : "")
    }
}
