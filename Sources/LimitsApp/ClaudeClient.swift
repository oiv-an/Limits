import AppKit
import LimitsCore
import SwiftUI

@MainActor
final class ClaudeConnection: ObservableObject {
    @Published var loginMessage =
        "Вход нужен только для подключения аккаунта. Подтверждать каждое обновление не потребуется."
    @Published var connecting = false
    /// Account being re-connected; nil means a new account will be added.
    @Published var targetName: String?
    let browserLogin = ClaudeBrowserLogin()
    var onSession: ((ClaudeSession, UUID?) async throws -> Void)?
    private var target: UUID?
    private var loginWindow: NSWindow?

    init() {
        browserLogin.onSuccess = { [weak self] session in self?.finishLogin(session: session) }
    }
    func showLogin(target: UUID?, name: String?) {
        if browserLogin.running, self.target != target { browserLogin.cancel() }
        self.target = target
        targetName = name
        loginMessage =
            name.map { "Повторный вход для «\($0)»." }
            ?? "Новый аккаунт Claude. Если браузер сразу входит в прежний аккаунт, выйдите из claude.ai в браузере."
        if loginWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 380),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Подключение Claude — Limits"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: ClaudeLoginView(connection: self, login: browserLogin))
            window.center()
            loginWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
        browserLogin.start()
    }
    private func finishLogin(session: ClaudeSession) {
        guard !connecting else { return }
        connecting = true
        loginMessage = "Сохраняем вход и получаем лимиты…"
        let target = self.target
        Task {
            defer { connecting = false }
            do {
                try await onSession?(session, target)
                loginMessage = "Claude подключён."
                browserLogin.message = "Подключение сохранено. Лимиты обновляются автоматически."
                loginWindow?.orderOut(nil)
            } catch {
                loginMessage =
                    (error as? UsageError)?.localizedDescription
                    ?? "Вход сохранён, но лимиты пока не удалось получить. Повторим автоматически."
            }
        }
    }
    func stopLogin() { browserLogin.cancel() }
}

struct ClaudeLoginView: View {
    @ObservedObject var connection: ClaudeConnection
    @ObservedObject var login: ClaudeBrowserLogin
    @State private var showCode = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(
                    Color.claudeAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.targetName.map { "Войти: \($0)" } ?? "Добавить аккаунт Claude")
                        .font(.system(size: 21, weight: .semibold)).lineLimit(1)
                    Text("Google, Apple или email — в вашем браузере").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text(login.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                if login.running || connection.connecting {
                    ProgressView().controlSize(.small)
                    Button("Открыть браузер") { login.reopenBrowser() }
                        .disabled(!login.hasBrowserLink || login.exchanging)
                    Spacer()
                    Button("Отмена") { login.cancel() }.disabled(connection.connecting)
                } else {
                    Button("Войти через браузер") { login.start() }.buttonStyle(.borderedProminent)
                }
            }
            Divider()
            DisclosureGroup("Браузер показал код?", isExpanded: $showCode) {
                HStack {
                    SecureField("Код со страницы Claude", text: $login.code).textFieldStyle(
                        .roundedBorder
                    )
                    .onSubmit { login.submitCode() }
                    Button("Продолжить") { login.submitCode() }
                        .disabled(!login.running || login.exchanging || login.code.isEmpty)
                }.padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(connection.loginMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 470, height: 380).background(.regularMaterial)
    }
}
