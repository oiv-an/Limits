import AppKit
import Network
import LimitsCore

@MainActor
final class ClaudeBrowserLogin: ObservableObject {
    @Published var running = false
    @Published var exchanging = false
    @Published var message = "Войдите один раз. Подключение сохранится после сна и перезапуска Mac."
    @Published var hasBrowserLink = false
    @Published var code = ""
    var onSuccess: ((ClaudeSession) -> Void)?
    private var listener: NWListener?
    private var authorization: ClaudeAuthorization?
    private var timeout: Task<Void, Never>?
    private var exchange: Task<Void, Never>?
    private var attempt = UUID()

    func start() {
        guard !running else { reopenBrowser(); return }
        attempt = UUID()
        let id = attempt
        running = true; exchanging = false; hasBrowserLink = false; code = ""
        message = "Открываем вход в браузере…"
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.attempt == id, self.running else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        self.authorization = ClaudeAuthorization(port: port.rawValue)
                        self.hasBrowserLink = true
                        self.message = "Завершите вход в открывшемся браузере. Подключение сохранится автоматически."
                        self.reopenBrowser()
                    case .failed:
                        self.cancel()
                        self.message = "Не удалось открыть подключение. Нажмите «Войти через браузер» ещё раз."
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.attempt == id else { connection.cancel(); return }
                    connection.start(queue: .main)
                    self.receive(connection, data: Data(), attempt: id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { connection.cancel() }
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, let self, self.attempt == id else { return }
                self.cancel(); self.message = "Время ожидания истекло. Повторите вход, когда будет удобно."
            }
        } catch {
            running = false
            message = "Не удалось начать вход. Повторите попытку."
        }
    }

    private func receive(_ connection: NWConnection, data: Data, attempt id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.attempt == id, self.running else { connection.cancel(); return }
                let buffer = data + (chunk ?? Data())
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let line = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
                    guard line.count == 3, line[0] == "GET", let auth = self.authorization,
                          let code = auth.code(fromCallback: String(line[1])), !self.exchanging else {
                        self.respond(connection, accepted: false); return
                    }
                    self.respond(connection, accepted: true)
                    self.complete(code: code, authorization: auth, attempt: id)
                } else if buffer.count < 8192, !complete, error == nil {
                    self.receive(connection, data: buffer, attempt: id)
                } else { connection.cancel() }
            }
        }
    }

    private func respond(_ connection: NWConnection, accepted: Bool) {
        let title = accepted ? "Возвращайтесь в Limits" : "Этот переход не относится к текущему входу"
        let body = "<!doctype html><html lang=\"ru\"><meta charset=\"utf-8\"><title>Limits</title><body><h1>\(title)</h1><p>Можно закрыть эту вкладку.</p></body></html>"
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func complete(code: String, authorization: ClaudeAuthorization, attempt id: UUID) {
        guard !exchanging else { return }
        exchanging = true; message = "Сохраняем подключение…"
        exchange = Task {
            do {
                let session = try await ClaudeHTTPClient().exchange(code: code, verifier: authorization.verifier,
                    state: authorization.state, redirectURI: authorization.redirectURI)
                guard attempt == id else { return }
                finish(); message = "Вход выполнен. Получаем лимиты…"
                onSuccess?(session)
            } catch {
                guard attempt == id else { return }
                finish(); message = "Не удалось завершить вход. Проверьте интернет и повторите."
            }
        }
    }

    func reopenBrowser() {
        if let authorization { NSWorkspace.shared.open(authorization.url) }
    }
    func submitCode() {
        guard running, let authorization, let value = authorization.code(fromPaste: code) else {
            message = "Скопируйте код со страницы Claude целиком."; return
        }
        code = ""; complete(code: value, authorization: authorization, attempt: attempt)
    }
    func cancel() {
        attempt = UUID(); exchange?.cancel(); exchange = nil
        finish(); message = "Вход отменён. Можно повторить в любой момент."
    }
    private func finish() {
        timeout?.cancel(); timeout = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        authorization = nil; running = false; exchanging = false; hasBrowserLink = false; code = ""
    }
}
