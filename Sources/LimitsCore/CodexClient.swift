import Foundation
import Darwin

public enum CodexClient {
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// A short-lived read-only RPC connection. It never creates a thread or runs a model.
    public static func fetch(timeout: TimeInterval = 30) throws -> UsageSnapshot {
        guard let executable = executable() else { throw UsageError.signIn("Установите Codex и войдите в аккаунт ChatGPT.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let end = Date().addingTimeInterval(1)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ivol_limits", "title": "Limits", "version": "1.0.0"]]])
        let deadline = Date().addingTimeInterval(timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        var buffer = Data()
        while Date() < deadline {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, 200)
            if polled < 0 { if errno == EINTR { continue }; break }
            if polled == 0 { continue }
            if descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 4_194_304 else { throw UsageError.invalidResponse }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                    if message["error"] != nil {
                        throw UsageError.unavailable("Codex не смог получить лимиты. Проверьте вход и соединение.")
                    }
                    if id == 1 {
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/rateLimits/read"])
                    } else if id == 2 {
                        return try UsageParser.codex(line)
                    }
                }
            } else if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
        }
        throw UsageError.unavailable("Codex не ответил. Откройте Codex и проверьте подключение.")
    }
}
