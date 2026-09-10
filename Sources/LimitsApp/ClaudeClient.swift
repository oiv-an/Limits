import AppKit
import Security
import LocalAuthentication
import LimitsCore

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == task.originalRequest?.url?.host && request.url?.scheme == "https" ? request : nil)
    }
}

enum UsageHTTP {
    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.signIn("Войдите в Claude заново, чтобы читать лимиты.")
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 900
            throw UsageError.retryLater(seconds: max(300, min(seconds, 86400)))
        default: throw UsageError.unavailable("Claude временно недоступен (\(http.statusCode)).")
        }
    }
}

enum ClaudeOAuth {
    static func fetch(token: String) async throws -> UsageSnapshot {
        let data = try await UsageHTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
                      "anthropic-version": "2023-06-01", "User-Agent": "Limits/1.0.4", "x-app": "cli"])
        return try UsageParser.claude(data, source: "Claude Code")
    }
}

import SwiftUI

struct ClaudeOrganization: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class ClaudeConnection: ObservableObject {
    @Published var organizations: [ClaudeOrganization] = []
    @Published var loginMessage = "В браузере подключение называется Claude Code — это официальный компонент, через который Limits читает лимиты."
    @Published var connecting = false
    let browserLogin = ClaudeBrowserLogin()
    var onConnected: ((UsageSnapshot) -> Void)?
    var onError: ((Error) -> Void)?
    private var loginWindow: NSWindow?
    private var fetchTask: Task<UsageSnapshot, Error>?
    private var retryUntil: Date?
    private var authorizedToken: String?
    private var generation = 0

    init() {
        browserLogin.onSuccess = { [weak self] in self?.finishLogin() }
    }
    var selectedOrganization: String {
        get { UserDefaults.standard.string(forKey: "claudeOrganization") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeOrganization"); objectWillChange.send() }
    }
    func fetch() async throws -> UsageSnapshot {
        if let task = fetchTask { return try await task.value }
        if let retryUntil, retryUntil > Date() { throw UsageError.retryLater(seconds: retryUntil.timeIntervalSinceNow) }
        let requestGeneration = generation
        let task = Task { () throws -> UsageSnapshot in
            guard let token = self.authorizedToken else {
                throw UsageError.locked("Разблокируйте подключение через Touch ID. Фоновые обновления не запрашивают пароль.")
            }
            return try await ClaudeOAuth.fetch(token: token)
        }
        fetchTask = task
        defer { if generation == requestGeneration { fetchTask = nil } }
        do { return try await task.value }
        catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case UsageError.retryLater(let delay) = error { retryUntil = Date().addingTimeInterval(delay) }
            if case UsageError.signIn = error { authorizedToken = nil }
            throw error
        }
    }
    func showLogin() {
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 445),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Подключение Claude — Limits"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ClaudeLoginView(connection: self, login: browserLogin))
            window.center(); loginWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); loginWindow?.makeKeyAndOrderFront(nil)
        browserLogin.start()
    }
    func finishLogin() { unlock(importExisting: true) }

    func unlock(importExisting: Bool = false) {
        guard !connecting else { return }
        connecting = true
        let startingGeneration = generation
        loginMessage = "Приложите палец к Touch ID. После разблокировки лимиты обновляются без запросов."
        Task {
            defer { connecting = false }
            do {
                let context = try await ClaudeTouchID.authenticate()
                defer { context.invalidate() }
                guard generation == startingGeneration else { return }
                let token = try await Task.detached(priority: .userInitiated) {
                    try ClaudeTouchID.read(context: context, importExisting: importExisting)
                }.value
                guard generation == startingGeneration else { return }
                authorizedToken = token
                generation += 1
                fetchTask?.cancel(); fetchTask = nil
                let snapshot = try await fetch()
                loginMessage = "Claude подключён через Touch ID."
                browserLogin.message = "Claude подключён. Лимиты обновляются автоматически."
                onConnected?(snapshot)
                loginWindow?.orderOut(nil)
                recordUnlock(success: true)
            } catch {
                let message = (error as? UsageError)?.localizedDescription
                    ?? "Не удалось разблокировать подключение. Повторите Touch ID или войдите в Claude заново."
                loginMessage = message
                onError?(error is UsageError ? error : UsageError.locked(message))
                recordUnlock(success: false, error: error)
                if case UsageError.signIn = error, !importExisting { showLogin() }
            }
        }
    }

    func lock() {
        authorizedToken = nil; generation += 1
        fetchTask?.cancel(); fetchTask = nil
        onError?(UsageError.locked("Подключение заблокировано. Для обновления лимитов используйте Touch ID."))
    }

    private func recordUnlock(success: Bool, error: Error? = nil) {
        let url = ClaudeTouchID.vaultURL.deletingLastPathComponent().appendingPathComponent("touch-id-state.json")
        var state: [String: Any] = ["unlocked": success, "savedWithTouchID": ClaudeTouchID.hasSavedConnection,
            "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let error { state["errorDomain"] = (error as NSError).domain; state["errorCode"] = (error as NSError).code }
        try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func stopLogin() { browserLogin.cancel() }
}

struct ClaudeLoginView: View {
    @ObservedObject var connection: ClaudeConnection
    @ObservedObject var login: ClaudeBrowserLogin
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(Color.claudeAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude в вашем браузере").font(.system(size: 20, weight: .semibold))
                    Text("Вход через Google, Apple или email").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(login.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                if login.running {
                    ProgressView().controlSize(.small)
                    Button("Открыть браузер ещё раз") { login.reopenBrowser() }.disabled(!login.hasBrowserLink)
                    Spacer()
                    Button("Отмена") { login.cancel() }
                } else {
                    Button("Войти через браузер") { login.start() }.buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("Если браузер показал код авторизации").font(.system(size: 12, weight: .medium))
                HStack {
                    SecureField("Вставьте код сюда", text: $login.code).textFieldStyle(.roundedBorder)
                        .onSubmit { login.submitCode() }
                    Button("Подтвердить") { login.submitCode() }.disabled(!login.running || login.code.isEmpty)
                }
                Text("Обычно вход завершается автоматически. Код нужен только если браузер попросил его скопировать.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(connection.loginMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(connection.connecting ? "Проверяем…" : "Подтвердить Touch ID") { connection.finishLogin() }
                    .disabled(connection.connecting || login.running)
            }
        }.padding(24).frame(width: 490, height: 445).background(.regularMaterial)
    }
}
