import Foundation

public struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var durationMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id; self.title = title; self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }

    public var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    // Never claim 100% remains just because the reset time has passed.
    public func isExpired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public var percentageText: String {
        if remaining > 0 && remaining < 1 { return "<1%" }
        return "\(Int(remaining.rounded(.down)))%"
    }

    public static func periodTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Период" }
        if minutes == 10080 { return "Неделя" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) дн." }
        if minutes % 60 == 0 { return "\(minutes / 60) ч" }
        return "\(minutes) мин"
    }
}

public struct UsageGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var windows: [UsageWindow]
    public init(id: String, title: String, windows: [UsageWindow]) {
        self.id = id; self.title = title; self.windows = windows
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: String
    public var plan: String?
    public var groups: [UsageGroup]
    public var fetchedAt: Date
    public var source: String
    public init(provider: String, plan: String? = nil, groups: [UsageGroup], fetchedAt: Date = Date(), source: String) {
        self.provider = provider; self.plan = plan; self.groups = groups; self.fetchedAt = fetchedAt; self.source = source
    }
    public func headline(groupID: String? = nil, at now: Date = Date()) -> UsageWindow? {
        let group = groups.first(where: { $0.id == groupID }) ?? groups.first
        return group?.windows.filter { !$0.isExpired(at: now) }.min { $0.remaining < $1.remaining }
    }
    public func isStale(at now: Date = Date(), interval: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(fetchedAt) > max(600, interval * 2.5)
    }
}

public enum UsageError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case signIn(String)
    case locked(String)
    case retryLater(seconds: TimeInterval)
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .signIn(let message), .locked(let message): return message
        case .retryLater: return "Сервис просит подождать. Повторим автоматически."
        case .invalidResponse: return "Сервис вернул неизвестный формат лимитов."
        }
    }
}

public enum UsageParser {
    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        let result = root["result"] as? [String: Any] ?? root
        var buckets = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        if buckets.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            buckets[legacy["limitId"] as? String ?? "codex"] = legacy
        }
        var groups: [UsageGroup] = []
        var plan: String?
        for id in buckets.keys.sorted(by: { a, b in
            if a == "codex" { return b != "codex" }
            if b == "codex" { return false }
            return a < b
        }) {
            guard let bucket = buckets[id] as? [String: Any] else { continue }
            if plan == nil { plan = bucket["planType"] as? String }
            var windows: [UsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let w = bucket[key] as? [String: Any], let used = number(w["usedPercent"]) else { continue }
                let minutes = number(w["windowDurationMins"]).map(Int.init)
                windows.append(UsageWindow(id: "\(id)-\(key)", title: UsageWindow.periodTitle(minutes: minutes),
                    usedPercent: used, durationMinutes: minutes, resetsAt: number(w["resetsAt"]).map(Date.init(timeIntervalSince1970:))))
            }
            if !windows.isEmpty {
                groups.append(UsageGroup(id: id, title: bucket["limitName"] as? String ?? (id == "codex" ? "Codex" : id), windows: windows))
            }
        }
        guard !groups.isEmpty else { throw UsageError.unavailable("Аккаунт не передал лимиты подписки.") }
        return UsageSnapshot(provider: "codex", plan: plan, groups: groups, fetchedAt: now, source: "Codex App Server")
    }

    public static func claude(_ data: Data, source: String, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        var standard: [UsageWindow] = []
        var groups: [UsageGroup] = []
        for key in ["five_hour", "seven_day"] + root.keys.filter({ $0.hasPrefix("seven_day_") }).sorted() {
            guard let w = root[key] as? [String: Any], let used = number(w["utilization"]) else { continue }
            let duration = key == "five_hour" ? 300 : 10080
            let window = UsageWindow(id: key, title: UsageWindow.periodTitle(minutes: duration), usedPercent: used,
                durationMinutes: duration, resetsAt: date(w["resets_at"]))
            if key == "five_hour" || key == "seven_day" { standard.append(window) }
            else {
                let names = ["seven_day_sonnet": "Sonnet", "seven_day_opus": "Opus",
                    "seven_day_oauth_apps": "OAuth-приложения", "seven_day_overage_included": "Дополнительный недельный лимит"]
                let title = names[key] ?? key.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
                groups.append(UsageGroup(id: key, title: title, windows: [window]))
            }
        }
        if !standard.isEmpty { groups.insert(UsageGroup(id: "claude", title: "Claude", windows: standard), at: 0) }
        guard !groups.isEmpty else { throw UsageError.unavailable("Claude не передал лимиты подписки для этого аккаунта.") }
        return UsageSnapshot(provider: "claude", groups: groups, fetchedAt: now, source: source)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

import CoreFoundation
