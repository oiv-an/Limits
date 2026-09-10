import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: UsageStore
    let installedInApplications: Bool
    let finish: (_ launchAtLogin: Bool, _ floating: Bool) -> Void
    @State private var launchAtLogin: Bool
    @State private var floating: Bool

    init(store: UsageStore, installedInApplications: Bool,
         finish: @escaping (_ launchAtLogin: Bool, _ floating: Bool) -> Void) {
        self.store = store
        self.installedInApplications = installedInApplications
        self.finish = finish
        _launchAtLogin = State(initialValue: store.launchAtLogin)
        _floating = State(initialValue: store.floating)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 13) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 78, height: 78)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                Text("Добро пожаловать в Limits")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Лимиты Codex и Claude всегда рядом — в строке меню Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.top, 27).padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 15) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(installedInApplications ? "Приложение установлено" : "Перетащите Limits в папку «Программы»")
                            .font(.system(size: 13, weight: .medium))
                        Text(installedInApplications
                             ? "Можно включить автозапуск и больше не открывать приложение вручную."
                             : "Автозапуск надёжно работает после запуска установленной копии.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: installedInApplications ? "checkmark.circle.fill" : "arrow.right.app")
                        .font(.system(size: 20)).foregroundStyle(installedInApplications ? Color.codexAccent : .orange)
                }

                Divider()

                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Запускать при входе в Mac").font(.system(size: 13, weight: .medium))
                        Text("Limits появится в строке меню автоматически.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).disabled(!installedInApplications)

                Toggle(isOn: $floating) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Показывать маленькую панель поверх окон").font(.system(size: 13, weight: .medium))
                        Text("Её можно перетаскивать и в любой момент скрыть.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch)
            }
            .padding(18)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.horizontal, 28)

            HStack {
                Text("Аккаунты подключаются локально после установки.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Начать") { finish(launchAtLogin, floating) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
        }
        .frame(width: 520, height: 450)
        .background(.regularMaterial)
    }
}
