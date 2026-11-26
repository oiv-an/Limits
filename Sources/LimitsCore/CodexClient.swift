import Darwin
import Foundation

public enum CodexClient {
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(
            URL.init(fileURLWithPath:))
    }

    /// Result of one read: limits plus the possibly rotated `auth.json` that must be saved back.
    public struct Reading: Sendable {
        public var snapshot: UsageSnapshot
        public var auth: Data
        public var email: String?
    }

    /// Private, isolated CODEX_HOME. Never the user's ~/.codex, so Codex.app keeps its own login.
    private static func temporaryHome() throws -> URL {
        let root = AccountVault.directory.appendingPathComponent("codex-tmp")
        let manager = FileManager.default
        try manager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let home = root.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(
            at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return home
    }

    /// Removes homes left by a crash or forced quit; they may contain tokens.
    public static func removeTemporaryHomes() {
        try? FileManager.default.removeItem(
            at: AccountVault.directory.appendingPathComponent("codex-tmp"))
    }

    private static func process(_ executable: URL, home: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\""] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment
        process.currentDirectoryURL = home
        return process
    }

    private static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        let end = Date().addingTimeInterval(1)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func readAuth(in home: URL) -> Data? {
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url), data.count <= 262_144,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["tokens"] is [String: Any]
        else { return nil }
        return data
    }

    /// Email from the id_token claims in auth.json; used only as the default account name.
    public static func email(fromAuth data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String
        else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let decoded = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
            ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    /// Browser login into a fresh isolated home. Returns the new `auth.json` to keep in the vault.
    public static func login(timeout: TimeInterval = 600) throws -> Data {
        guard let executable = executable() else {
            throw UsageError.signIn("Установите Codex, затем повторите вход.")
        }
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = process(executable, home: home, arguments: ["login"])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task<Never, Never>.checkCancellation()
        try process.run()
        defer { stop(process) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task<Never, Never>.checkCancellation()
            guard Date() < deadline else {
                throw UsageError.unavailable("Время ожидания истекло. Повторите вход в Codex.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try Task<Never, Never>.checkCancellation()
        guard process.terminationStatus == 0, let auth = readAuth(in: home) else {
            throw UsageError.unavailable(
                "Не удалось войти в Codex. Повторите попытку; закройте другие окна входа Codex.")
        }
        return auth
    }

    /// A short-lived read-only RPC connection for one stored account. It never creates a thread or runs a model.
    /// Tokens exist on disk only inside a private temporary home for the duration of the call.
    /// `authChanged` receives rotated tokens even when the read itself fails, so they are never lost.
    public static func fetch(
        auth: Data, timeout: TimeInterval = 30, authChanged: (Data) -> Void = { _ in }
    ) throws -> Reading {
        guard let executable = executable() else {
            throw UsageError.unavailable(
                "Установите Codex: Limits использует его для чтения лимитов.")
        }
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authURL = home.appendingPathComponent("auth.json")
        guard
            FileManager.default.createFile(
                atPath: authURL.path, contents: auth, attributes: [.posixPermissions: 0o600])
        else { throw UsageError.unavailable("Не удалось подготовить чтение лимитов Codex.") }
        let process = process(executable, home: home, arguments: ["app-server", "--stdio"])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = Result { try rateLimits(input: input, output: output, timeout: timeout) }
        try? input.fileHandleForWriting.close()
        stop(process)
        try? output.fileHandleForReading.close()
        // Codex may have refreshed and rotated the tokens; the new file must replace the stored one.
        let updated = readAuth(in: home) ?? auth
        if updated != auth { authChanged(updated) }
        return Reading(snapshot: try result.get(), auth: updated, email: email(fromAuth: updated))
    }

    private static func rateLimits(input: Pipe, output: Pipe, timeout: TimeInterval) throws
        -> UsageSnapshot
    {
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send([
            "id": 1, "method": "initialize",
            "params": [
                "clientInfo": ["name": "ivol_limits", "title": "Limits", "version": "1.3.0"]
            ],
        ])
        let deadline = Date().addingTimeInterval(timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        var buffer = Data()
        while Date() < deadline {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, 200)
            if polled < 0 {
                if errno == EINTR { continue }
                break
            }
            if polled == 0 { continue }
            if descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 4_194_304 else { throw UsageError.invalidResponse }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard
                        let message = try? JSONSerialization.jsonObject(with: line)
                            as? [String: Any], let id = message["id"] as? Int
                    else { continue }
                    if let error = message["error"] as? [String: Any] {
                        let text = (error["message"] as? String ?? "").lowercased()
                        if text.contains("auth") || text.contains("login") {
                            throw UsageError.signIn(
                                "Вход в этот аккаунт Codex истёк. Войдите заново.")
                        }
                        throw UsageError.unavailable(
                            "Codex не смог получить лимиты. Проверьте соединение.")
                    }
                    if id == 1 {
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/rateLimits/read"])
                    } else if id == 2 {
                        return try UsageParser.codex(line)
                    }
                }
            } else if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                break
            }
        }
        throw UsageError.unavailable("Codex не ответил. Проверьте подключение к интернету.")
    }
}
