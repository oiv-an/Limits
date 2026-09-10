import AppKit
import LimitsCore

struct CompactUsage {
    let name: String
    let symbol: String
    let value: String
    let reset: String
    let help: String

    init(state: ProviderState, claude: Bool = false, groupID: String? = nil,
         interval: TimeInterval, now: Date = Date()) {
        name = claude ? "Claude" : "Codex"
        symbol = claude ? "asterisk" : "terminal"
        let windows: [UsageWindow?]
        if claude {
            let standard = state.snapshot?.groups.first { $0.id == "claude" }?.windows ?? []
            // Keep both positions even when a period is missing or awaiting fresh data.
            windows = ["five_hour", "seven_day"].map { id in standard.first { $0.id == id } }
        } else {
            let group = state.snapshot?.groups.first { $0.id == groupID } ?? state.snapshot?.groups.first
            windows = [state.snapshot?.headline(groupID: groupID, at: now) ?? group?.windows.first]
        }
        if state.snapshot == nil {
            value = state.loading ? "…" : "—"
            reset = "—"
        } else {
            let percentages = windows.map { window -> String in
                guard let window else { return "—" }
                return window.isExpired(at: now) ? "…" : window.percentageText.replacingOccurrences(of: "%", with: "")
            }
            let hasPercentage = windows.contains { $0.map { !$0.isExpired(at: now) } ?? false }
            value = percentages.joined(separator: "/") + (hasPercentage ? "%" : "")
                + (state.stale(interval: interval) ? "·" : "")
            reset = windows.map { window in
                guard let date = window?.resetsAt else { return "—" }
                return date <= now ? "…" : Self.remainingTime(date.timeIntervalSince(now))
            }.joined(separator: "/")
        }
        var details = windows.enumerated().map { index, window -> String in
            let period = window?.title ?? (claude ? (index == 0 ? "5 ч" : "Неделя") : "Лимит")
            guard let window else { return "\(period): нет данных" }
            if window.isExpired(at: now) { return "\(period): ждём обновления после сброса" }
            let reset = window.resetsAt.map { " · сброс через \(countdown($0.timeIntervalSince(now)))" } ?? ""
            return "\(period): осталось \(window.percentageText)\(reset)"
        }
        if let message = state.message { details.append(message) }
        help = name + "\n" + details.joined(separator: "\n")
    }

    private static func remainingTime(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)д \((minutes % 1440) / 60)ч" }
        if minutes >= 60 { return "\(minutes / 60)ч \(minutes % 60)м" }
        return "\(minutes)м"
    }
}

enum MenuBarImage {
    static func make(_ summaries: [CompactUsage]) -> NSImage {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let timerAttributes: [NSAttributedString.Key: Any] = [.font: timerFont, .foregroundColor: NSColor.black]
        let widths = summaries.map { summary in
            ceil(max((summary.value as NSString).size(withAttributes: valueAttributes).width,
                     (summary.reset as NSString).size(withAttributes: timerAttributes).width + 10)) + 21
        }
        let size = NSSize(width: widths.reduce(0, +) + CGFloat(max(0, summaries.count - 1)) * 13, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, summary) in summaries.enumerated() {
                let symbol = NSImage(systemSymbolName: summary.symbol, accessibilityDescription: nil)
                symbol?.draw(in: NSRect(x: x, y: 4, width: 15, height: 15))
                (summary.value as NSString).draw(at: NSPoint(x: x + 21, y: 10), withAttributes: valueAttributes)
                let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
                clock?.draw(in: NSRect(x: x + 21, y: 1, width: 7, height: 7))
                (summary.reset as NSString).draw(at: NSPoint(x: x + 31, y: 0), withAttributes: timerAttributes)
                x += widths[index] + 13
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
