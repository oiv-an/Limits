import LimitsCore
import SwiftUI

extension Color {
    static let codexAccent = Color(red: 0.32, green: 0.79, blue: 0.65)
    static let claudeAccent = Color(red: 0.86, green: 0.57, blue: 0.43)
    static func quota(_ remaining: Double, accent: Color) -> Color {
        remaining <= 10 ? .red : (remaining <= 25 ? .orange : accent)
    }
}

extension UsageStore {
    func summaries(now: Date = Date()) -> [CompactUsage] {
        accounts.map {
            CompactUsage(
                account: $0, badge: badge(for: $0),
                groupID: $0.provider == .codex ? codexGroup : nil, interval: interval, now: now)
        }
    }
    /// Width of the floating panel for the current number of accounts.
    var floatingWidth: CGFloat {
        let columns = accounts.map { $0.provider == .claude ? 124.0 : 88.0 }
        let content = columns.reduce(0, +) + Double(max(0, columns.count - 1)) * 25
        return CGFloat(max(150, content + 44 + 8))
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var settings = false
    @State private var renaming: AccountState?
    @State private var newName = ""
    @State private var removing: AccountState?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Лимиты").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Осталось в подписках").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Аккаунт Claude…") { store.addClaude() }
                    Button("Аккаунт Codex…") { store.loginCodex(target: nil) }
                        .disabled(store.codexAuthenticating)
                } label: {
                    Image(systemName: "plus.circle").frame(width: 24, height: 24)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Добавить аккаунт").accessibilityLabel("Добавить аккаунт")
                Button {
                    store.floating.toggle()
                } label: {
                    Image(systemName: store.floating ? "pin.fill" : "pin").frame(
                        width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(
                    store.floating ? Color.accentColor : .secondary
                )
                .help("Закрепить маленькую панель поверх окон").accessibilityLabel(
                    "Панель поверх окон")
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.buttonStyle(.plain).disabled(store.anyLoading)
                    .help("Обновить лимиты").accessibilityLabel("Обновить лимиты")
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 17)
            ScrollView {
                VStack(spacing: 12) {
                    if let message = store.vaultMessage {
                        Notice(text: message, color: .orange)
                    }
                    if store.codexAuthenticating || store.codexLoginMessage != nil {
                        HStack(alignment: .top, spacing: 8) {
                            if store.codexAuthenticating { ProgressView().controlSize(.small) }
                            Text(store.codexLoginMessage ?? "Вход в Codex…")
                                .font(.system(size: 11)).fixedSize(
                                    horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(store.codexAuthenticating ? "Отмена" : "Скрыть") {
                                if store.codexAuthenticating {
                                    store.cancelCodexAuthentication()
                                } else {
                                    store.codexLoginMessage = nil
                                }
                            }.controlSize(.small)
                        }.padding(12).background(
                            Color.codexAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if store.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                "Добавьте аккаунты подписок. Можно несколько Claude и несколько Codex."
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Добавить Claude") { store.addClaude() }
                                    .buttonStyle(.bordered).tint(.claudeAccent)
                                Button("Добавить Codex") { store.loginCodex(target: nil) }
                                    .buttonStyle(.bordered).tint(.codexAccent)
                                    .disabled(store.codexAuthenticating)
                            }
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15)
                            )
                    }
                    ForEach(store.accounts) { account in
                        ProviderCard(
                            account: account, badge: store.badge(for: account),
                            interval: store.interval,
                            selectedGroup: account.provider == .codex ? store.codexGroup : nil,
                            connect: { store.reconnect(account.id) },
                            refresh: { store.refresh(account.id, force: true) },
                            rename: {
                                newName = account.name
                                renaming = account
                            },
                            remove: { removing = account })
                    }
                    if settings { SettingsContent(store: store) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }.frame(maxHeight: settings ? 560 : 520)
            Divider()
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(updateText(now: context.date)).font(.system(size: 10)).foregroundStyle(
                            .secondary)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { settings.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("Настройки").accessibilityLabel("Настройки")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power").frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("Завершить Limits").accessibilityLabel(
                    "Завершить Limits")
            }.padding(.horizontal, 18).padding(.vertical, 9)
        }
        .frame(width: 356)
        .background(.regularMaterial)
        .alert(
            "Название аккаунта",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(renaming?.email ?? "Название", text: $newName)
            Button("Сохранить") {
                if let account = renaming { store.rename(account.id, to: newName) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            Text("Пустое название — использовать email аккаунта.")
        }
        .alert(
            "Удалить «\(removing?.name ?? "")»?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Удалить", role: .destructive) {
                if let account = removing { store.remove(account.id) }
                removing = nil
            }
            Button("Отмена", role: .cancel) { removing = nil }
        } message: {
            Text(
                "Вход этого аккаунта будет удалён из Limits. Сам аккаунт и другие приложения не затрагиваются."
            )
        }
    }
    private var statusColor: Color {
        if store.anyLoading { return .secondary }
        return store.accounts.contains { $0.state.message != nil } ? .orange : .codexAccent
    }
    private func updateText(now: Date) -> String {
        if store.anyLoading { return "Обновляем…" }
        let dates = store.accounts.compactMap { $0.state.snapshot?.fetchedAt }
        guard let date = dates.min() else {
            return "Автообновление · \(Int(store.interval / 60)) мин"
        }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes < 1 ? "Обновлено только что" : "Обновлено \(minutes) мин назад"
    }
}

private struct Notice: View {
    let text: String
    let color: Color
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.system(size: 11))
            .foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProviderCard: View {
    let account: AccountState
    let badge: String?
    let interval: TimeInterval
    var selectedGroup: String? = nil
    let connect: () -> Void
    let refresh: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var expanded = false

    private var state: ProviderState { account.state }
    private var name: String { account.provider.title }
    private var mark: String { account.provider == .claude ? "asterisk" : "terminal" }
    private var accent: Color { account.provider == .claude ? .claudeAccent : .codexAccent }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let headline = state.snapshot?.headline(groupID: selectedGroup, at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: mark).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent).frame(width: 32, height: 32)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .bottomTrailing) {
                            if let badge {
                                Text(badge).font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white).frame(width: 13, height: 13)
                                    .background(accent, in: Circle()).offset(x: 3, y: 3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                            .help(account.email ?? account.name)
                        Text(
                            [name, state.snapshot?.plan?.capitalized].compactMap { $0 }.joined(
                                separator: " · ")
                        ).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Обновить") { refresh() }.disabled(state.loading)
                        Button("Переименовать…") { rename() }
                        Button("Войти заново…") { connect() }
                        Divider()
                        Button("Удалить аккаунт…", role: .destructive) { remove() }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 18, height: 18)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(.secondary).accessibilityLabel("Действия с аккаунтом")
                    if let headline {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(headline.percentageText).font(
                                .system(size: 26, weight: .medium, design: .rounded)
                            ).monospacedDigit()
                                .foregroundStyle(Color.quota(headline.remaining, accent: accent))
                            Text(headline.title.lowercased()).font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine).accessibilityLabel(
                            "Осталось \(headline.percentageText), \(headline.title)")
                    } else if state.loading {
                        ProgressView().controlSize(.small).frame(width: 38)
                    } else {
                        Text("—").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    }
                }
                if let snapshot = state.snapshot {
                    let chosen =
                        snapshot.groups.first(where: { $0.id == selectedGroup })
                        ?? snapshot.groups.first
                    if let chosen {
                        if chosen.title != name {
                            Text(chosen.title).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chosen.windows) { window in
                            QuotaRow(window: window, accent: accent, now: context.date)
                        }
                    }
                    let others = snapshot.groups.filter { $0.id != chosen?.id }
                    if !others.isEmpty {
                        Button {
                            withAnimation { expanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(
                                    expanded
                                        ? "Скрыть остальные лимиты" : "Ещё лимиты · \(others.count)"
                                )
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(
                                    .system(size: 8, weight: .bold))
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                        if expanded {
                            ForEach(others) { group in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(group.title).font(.system(size: 11, weight: .medium))
                                    ForEach(group.windows) {
                                        QuotaRow(window: $0, accent: accent, now: context.date)
                                    }
                                }.padding(.top, 3)
                            }
                        }
                    }
                    if state.stale(interval: interval) {
                        Label(
                            state.message ?? "Данные устарели. Обновляем автоматически.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(
                            horizontal: false, vertical: true)
                    }
                } else {
                    Text(
                        state.message
                            ?? (state.loading
                                ? "Получаем лимиты…" : "Подключите аккаунт для чтения лимитов.")
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    if !state.loading || state.needsLogin {
                        Button(action: connect) {
                            HStack(spacing: 6) {
                                Text("Войти в \(name)")
                                Image(systemName: "arrow.up.right").font(
                                    .system(size: 9, weight: .semibold))
                            }.font(.system(size: 11, weight: .medium)).padding(.vertical, 3)
                        }.buttonStyle(.bordered).tint(accent)
                    }
                }
            }.padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                .overlay(
                    RoundedRectangle(cornerRadius: 15).strokeBorder(
                        Color.primary.opacity(0.06), lineWidth: 1))
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
                Text(expired ? "Обновляется…" : "\(window.percentageText) осталось")
                    .monospacedDigit()
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
                Text(
                    expired
                        ? "Период закончился · ждём свежие данные"
                        : "Сброс через \(countdown(reset.timeIntervalSince(now)))"
                )
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
            Text("НАСТРОЙКИ").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(
                .secondary)
            Toggle("Панель поверх окон", isOn: $store.floating).toggleStyle(.switch).controlSize(
                .mini)
            Toggle(
                "Запускать при входе в Mac",
                isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin)
            )
            .toggleStyle(.switch).controlSize(.mini)
            Picker("Обновлять", selection: $store.interval) {
                Text("Раз в 2 минуты").tag(120.0)
                Text("Раз в 5 минут").tag(300.0)
                Text("Раз в 10 минут").tag(600.0)
            }.controlSize(.small)
            if let groups = store.accounts.first(where: {
                $0.provider == .codex && ($0.state.snapshot?.groups.count ?? 0) > 1
            })?.state.snapshot?.groups {
                Picker("Лимит Codex", selection: $store.codexGroup) {
                    ForEach(groups) { Text($0.title).tag($0.id) }
                }.controlSize(.small)
            }
            Text(
                "Все входы хранятся в одном зашифрованном файле. Ключ создаётся на этом Mac и доступен только Limits; на другом Mac аккаунты нужно будет подключить заново."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            if let message = store.settingsMessage {
                Text(message).foregroundStyle(.orange).font(.caption)
            }
            Text(
                "Claude: остаток на 5 часов / неделю. Под процентами — время до сброса в том же порядке. Codex показывает наименьший остаток выбранного лимита. Точка после процентов — сохранённые данные."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
        }.font(.system(size: 11)).padding(4)
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
                    if store.accounts.isEmpty {
                        Text("Добавьте аккаунт").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(zip(store.accounts, store.summaries(now: now))), id: \.0.id) {
                        account, summary in
                        if account.id != store.accounts.first?.id {
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 27)
                        }
                        column(
                            summary,
                            color: account.provider == .claude ? .claudeAccent : .codexAccent,
                            width: account.provider == .claude ? 124 : 88)
                    }
                }
            }.buttonStyle(.plain)
            Button {
                store.floating = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(
                    .tertiary
                ).frame(width: 24, height: 44)
            }.buttonStyle(.plain).help("Скрыть плавающую панель")
        }.frame(width: store.floatingWidth, height: 65)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    Color.primary.opacity(0.09), lineWidth: 1))
    }
    private func column(_ summary: CompactUsage, color: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: summary.symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = summary.badge {
                            Text(badge).font(.system(size: 7, weight: .bold)).foregroundStyle(
                                .white
                            )
                            .frame(width: 10, height: 10).background(color, in: Circle())
                            .offset(x: 4, y: 4)
                        }
                    }
                Text(summary.value).font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 8))
                Text(summary.reset).font(.system(size: 10)).monospacedDigit()
            }.foregroundStyle(.secondary)
        }.frame(width: width, alignment: .leading).help(summary.help)
            .accessibilityElement(children: .ignore).accessibilityLabel(summary.help)
    }
}
