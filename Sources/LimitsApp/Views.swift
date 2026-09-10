import SwiftUI
import LimitsCore

extension Color {
    static let codexAccent = Color(red: 0.32, green: 0.79, blue: 0.65)
    static let claudeAccent = Color(red: 0.86, green: 0.57, blue: 0.43)
    static func quota(_ remaining: Double, accent: Color) -> Color {
        remaining <= 10 ? .red : (remaining <= 25 ? .orange : accent)
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var settings = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Лимиты").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Осталось в подписках").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.floating.toggle() } label: {
                    Image(systemName: store.floating ? "pin.fill" : "pin").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(store.floating ? Color.accentColor : .secondary)
                    .help("Закрепить маленькую панель поверх окон").accessibilityLabel("Панель поверх окон")
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.buttonStyle(.plain).disabled(store.codex.loading || store.claude.loading)
                    .help("Обновить лимиты").accessibilityLabel("Обновить лимиты")
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 17)
            ScrollView {
                VStack(spacing: 12) {
                    ProviderCard(name: "Codex", mark: "terminal", accent: .codexAccent, state: store.codex,
                        interval: store.interval, selectedGroup: store.codexGroup,
                        connect: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app")) })
                    ProviderCard(name: "Claude", mark: "asterisk", accent: .claudeAccent, state: store.claude,
                        interval: store.interval, connect: {
                            if store.claude.needsLogin { store.connection.showLogin() }
                            else { store.connection.unlock() }
                        })
                    if settings { SettingsContent(store: store) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }.frame(maxHeight: settings ? 540 : 450)
            Divider()
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(updateText(now: context.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.15)) { settings.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("Настройки").accessibilityLabel("Настройки")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("Завершить Limits").accessibilityLabel("Завершить Limits")
            }.padding(.horizontal, 18).padding(.vertical, 9)
        }
        .frame(width: 356)
        .background(.regularMaterial)
    }
    private var statusColor: Color {
        if store.codex.loading || store.claude.loading { return .secondary }
        return store.codex.message != nil || (store.claude.snapshot != nil && store.claude.message != nil) ? .orange : .codexAccent
    }
    private func updateText(now: Date) -> String {
        if store.codex.loading || store.claude.loading { return "Обновляем…" }
        let dates = [store.codex.snapshot?.fetchedAt, store.claude.snapshot?.fetchedAt].compactMap { $0 }
        guard let date = dates.min() else { return "Автообновление · \(Int(store.interval / 60)) мин" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes < 1 ? "Обновлено только что" : "Обновлено \(minutes) мин назад"
    }
}

private struct ProviderCard: View {
    let name: String
    let mark: String
    let accent: Color
    let state: ProviderState
    let interval: TimeInterval
    var selectedGroup: String? = nil
    let connect: () -> Void
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let headline = state.snapshot?.headline(groupID: selectedGroup, at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: mark).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent).frame(width: 32, height: 32)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 14, weight: .semibold))
                        if let plan = state.snapshot?.plan {
                            Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if state.snapshot != nil {
                            Text("Подключён").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let headline {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(headline.percentageText).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Color.quota(headline.remaining, accent: accent))
                            Text(headline.title.lowercased()).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine).accessibilityLabel("Осталось \(headline.percentageText), \(headline.title)")
                    } else if state.loading {
                        ProgressView().controlSize(.small).frame(width: 38)
                    } else {
                        Text("—").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    }
                }
                if let snapshot = state.snapshot {
                    let chosen = snapshot.groups.first(where: { $0.id == selectedGroup }) ?? snapshot.groups.first
                    if let chosen {
                        if chosen.title != name { Text(chosen.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                        ForEach(chosen.windows) { window in
                            QuotaRow(window: window, accent: accent, now: context.date)
                        }
                    }
                    let others = snapshot.groups.filter { $0.id != chosen?.id }
                    if !others.isEmpty {
                        Button { withAnimation { expanded.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text(expanded ? "Скрыть остальные лимиты" : "Ещё лимиты · \(others.count)")
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                        if expanded {
                            ForEach(others) { group in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(group.title).font(.system(size: 11, weight: .medium))
                                    ForEach(group.windows) { QuotaRow(window: $0, accent: accent, now: context.date) }
                                }.padding(.top, 3)
                            }
                        }
                    }
                    if state.stale(interval: interval) {
                        Label(state.message ?? "Данные устарели. Обновляем автоматически.", systemImage: "clock.badge.exclamationmark")
                            .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if state.requiresUnlock {
                        Button("Разблокировать Touch ID", systemImage: "touchid", action: connect)
                            .font(.system(size: 11, weight: .medium)).buttonStyle(.bordered).tint(accent)
                    }
                } else {
                    Text(state.loading ? "Получаем лимиты…" : (state.message ?? "Подключите аккаунт для чтения лимитов."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !state.loading || state.needsLogin {
                        Button(action: connect) {
                            HStack(spacing: 6) {
                                Text(state.requiresUnlock ? "Разблокировать Touch ID" : (name == "Claude" ? "Подключить Claude" : "Открыть Codex"))
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }.font(.system(size: 11, weight: .medium)).padding(.vertical, 3)
                        }.buttonStyle(.bordered).tint(accent)
                    }
                }
            }.padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }
}

private struct QuotaRow: View {
    let window: UsageWindow
    let accent: Color
    let now: Date
    var body: some View {
        let expired = window.isExpired(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title).foregroundStyle(.secondary)
                Spacer()
                Text(expired ? "Обновляется…" : "\(window.percentageText) осталось").monospacedDigit()
            }.font(.system(size: 11))
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        if !expired {
                            Capsule().fill(Color.quota(window.remaining, accent: accent))
                                .frame(width: geometry.size.width * window.remaining / 100)
                        }
                    }
            }.frame(height: 4)
            if let reset = window.resetsAt {
                Text(expired ? "Период закончился · ждём свежие данные" : "Сброс через \(countdown(reset.timeIntervalSince(now)))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Сброс: \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

func countdown(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440) дн. \((minutes % 1440) / 60) ч" }
    if minutes >= 60 { return "\(minutes / 60) ч \(minutes % 60) мин" }
    return "\(minutes) мин"
}

private struct SettingsContent: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("НАСТРОЙКИ").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Toggle("Панель поверх окон", isOn: $store.floating).toggleStyle(.switch).controlSize(.mini)
            Toggle("Запускать при входе в Mac", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
                .toggleStyle(.switch).controlSize(.mini)
            Picker("Обновлять", selection: $store.interval) {
                Text("Раз в 2 минуты").tag(120.0)
                Text("Раз в 5 минут").tag(300.0)
                Text("Раз в 10 минут").tag(600.0)
            }.controlSize(.small)
            if let groups = store.codex.snapshot?.groups, groups.count > 1 {
                Picker("В строке меню", selection: $store.codexGroup) {
                    ForEach(groups) { Text($0.title).tag($0.id) }
                }.controlSize(.small)
            }
            ClaudeAccountPicker(connection: store.connection, store: store)
            Button("Разблокировать Claude через Touch ID", systemImage: "touchid") { store.connection.unlock() }
                .buttonStyle(.link).disabled(store.connection.connecting)
            Button("Войти в Claude…") { store.connection.showLogin() }.buttonStyle(.link)
            Text("Touch ID нужен один раз после запуска или блокировки Mac. Фоновые обновления не запрашивают пароль.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = store.settingsMessage { Text(message).foregroundStyle(.orange).font(.caption) }
            Text("Claude: остаток на 5 часов / неделю. Под процентами — время до сброса в том же порядке. Codex показывает наименьший остаток выбранного лимита. Точка после процентов — сохранённые данные.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).padding(4)
    }
}

private struct ClaudeAccountPicker: View {
    @ObservedObject var connection: ClaudeConnection
    @ObservedObject var store: UsageStore
    var body: some View {
        if connection.organizations.count > 1 {
            Picker("Аккаунт Claude", selection: Binding(get: { connection.selectedOrganization }, set: {
                connection.selectedOrganization = $0; store.claude.snapshot = nil; store.refreshClaude(force: true)
            })) {
                Text("Выберите аккаунт").tag("")
                ForEach(connection.organizations) { Text($0.name).tag($0.id) }
            }.controlSize(.small)
        }
    }
}

struct FloatingView: View {
    @ObservedObject var store: UsageStore
    let openDashboard: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in content(now: context.date) }
    }
    private func content(now: Date) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(width: 20).help("Перетащите панель за свободное место")
            Button(action: openDashboard) {
                HStack(spacing: 12) {
                    column(CompactUsage(state: store.codex, groupID: store.codexGroup, interval: store.interval, now: now),
                           color: .codexAccent, width: 88)
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 27)
                    column(CompactUsage(state: store.claude, claude: true, interval: store.interval, now: now),
                           color: .claudeAccent, width: 124)
                }
            }.buttonStyle(.plain)
            Button { store.floating = false } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).frame(width: 24, height: 44)
            }.buttonStyle(.plain).help("Скрыть плавающую панель")
        }.frame(width: 292, height: 65)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
    private func column(_ summary: CompactUsage, color: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: summary.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                Text(summary.value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 8))
                Text(summary.reset).font(.system(size: 10)).monospacedDigit()
            }.foregroundStyle(.secondary)
        }.frame(width: width, alignment: .leading).help(summary.help)
            .accessibilityElement(children: .ignore).accessibilityLabel(summary.help)
    }
}
