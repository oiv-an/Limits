import Foundation
import Darwin

public struct ClaudeSessionFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ClaudeSession? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw UsageError.unavailable("Не удалось прочитать сохранённое подключение Claude.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= 65_536 else { throw UsageError.invalidResponse }
        guard let data = try handle.readToEnd() else { throw UsageError.invalidResponse }
        return try JSONDecoder().decode(ClaudeSession.self, from: data)
    }

    public func save(_ session: ClaudeSession) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw UsageError.unavailable("Не удалось сохранить подключение Claude.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(session))
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else {
            throw UsageError.unavailable("Не удалось сохранить подключение Claude.")
        }
    }
}
