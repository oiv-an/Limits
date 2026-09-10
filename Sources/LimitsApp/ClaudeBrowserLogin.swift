import AppKit
import CryptoKit
import LimitsCore

enum ClaudeTool {
    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pro.ivol.Limits/Tools/claude")
    }
    static func existingURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [installedURL.path, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
    static func prepare() async throws -> URL {
        if let existing = existingURL() { return existing }
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        let base = "https://downloads.claude.ai/claude-code-releases"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func read(_ url: String) async throws -> Data {
            let (data, response) = try await session.data(from: URL(string: url)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.unavailable("Не удалось загрузить компонент входа Claude.") }
            return data
        }
        let version = String(decoding: try await read(base + "/latest"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { throw UsageError.invalidResponse }
        let manifest = try JSONSerialization.jsonObject(with: await read(base + "/\(version)/manifest.json")) as? [String: Any]
        guard let platforms = manifest?["platforms"] as? [String: [String: Any]], let release = platforms[platform],
              let checksum = release["checksum"] as? String, checksum.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let size = release["size"] as? Int, size > 0, size < 600_000_000 else { throw UsageError.invalidResponse }
        let (temporary, response) = try await session.download(from: URL(string: "\(base)/\(version)/\(platform)/claude")!)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.unavailable("Не удалось загрузить компонент входа Claude.") }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var digest = SHA256(), received = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { received += chunk.count; digest.update(data: chunk) }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard received == size, actual == checksum else { throw UsageError.unavailable("Не удалось проверить компонент Claude. Повторите загрузку.") }
        let destination = installedURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }
}

@MainActor
final class ClaudeBrowserLogin: ObservableObject {
    @Published var running = false
    @Published var preparing = false
    @Published var message = "Войдите в Claude в обычном браузере. Можно использовать Google." { didSet { recordState() } }
    @Published var hasBrowserLink = false
    @Published var code = ""
    var onSuccess: (() -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = ""
    private var browserURL: URL?
    private var timeout: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var attemptID = UUID()

    func start() {
        guard !running else { reopenBrowser(); return }
        let attempt = UUID(); attemptID = attempt
        running = true; preparing = true; hasBrowserLink = false; browserURL = nil; code = ""
        message = ClaudeTool.existingURL() == nil ? "Загружаем официальный компонент входа Claude (около 200 МБ)…" : "Открываем вход в вашем браузере…"
        preparation = Task {
            do {
                let executable = try await ClaudeTool.prepare()
                guard attemptID == attempt else { return }
                preparing = false
                try launch(executable, attempt: attempt)
            } catch {
                guard attemptID == attempt else { return }
                running = false; preparing = false
                message = (error as? UsageError)?.localizedDescription ?? "Не удалось запустить вход. Проверьте интернет и повторите."
            }
        }
    }

    private func launch(_ executable: URL, attempt: UUID) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "login", "--claudeai"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Subscription sign-in must not be redirected by API key or remote-provider settings.
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_REMOTE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: key)
        }
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        self.input = input; self.output = output; self.process = process; outputBuffer = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.attemptID == attempt else { return }
                self.receive(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.attemptID == attempt else { return }
                self.finish(exitCode: process.terminationStatus)
            }
        }
        try process.run()
        message = "В открывшемся браузере выберите вход через Google и завершите авторизацию Claude."
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.attemptID == attempt else { return }
            self.cancel(); self.message = "Время ожидания истекло. Нажмите «Войти через браузер» ещё раз."
        }
    }

    private func receive(_ text: String) {
        outputBuffer = String((outputBuffer + text).suffix(32768))
        if let url = ClaudeAuthOutput.authorizationURL(in: outputBuffer) {
            browserURL = url; hasBrowserLink = true
            recordState()
        }
        // Raw CLI output and authentication URLs are never logged or shown as errors.
    }
    func reopenBrowser() {
        if let browserURL { NSWorkspace.shared.open(browserURL) }
    }
    func submitCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, !value.isEmpty, value.count < 4096, !value.contains("\n"), !value.contains("\r") else { return }
        do { try input?.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8)); code = "" }
        catch { message = "Не удалось передать код. Повторите вход через браузер." }
    }
    func cancel() {
        attemptID = UUID(); timeout?.cancel(); timeout = nil
        preparation?.cancel(); preparation = nil
        process?.terminationHandler = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; outputBuffer = ""; browserURL = nil
        running = false; preparing = false; hasBrowserLink = false; code = ""
        message = "Вход отменён. Можно повторить."
    }
    private func finish(exitCode: Int32) {
        timeout?.cancel(); timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil; outputBuffer = ""
        running = false; preparing = false; hasBrowserLink = false; browserURL = nil; code = ""
        if exitCode == 0 {
            message = "Вход выполнен. Получаем лимиты…"
            onSuccess?()
        } else { message = "Claude не завершил вход. Повторите попытку; код со страницы браузера можно вставить ниже." }
        recordState(exitCode: exitCode)
    }
    private func recordState(exitCode: Int32? = nil) {
        // Diagnostic status only: no URLs, codes, account details, tokens, or raw output.
        let directory = ClaudeTool.installedURL.deletingLastPathComponent().deletingLastPathComponent()
        let url = directory.appendingPathComponent("login-state.json")
        var state: [String: Any] = ["running": running, "preparing": preparing, "browserLinkReady": hasBrowserLink,
                                    "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let exitCode { state["exitCode"] = exitCode }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { }
    }
}
