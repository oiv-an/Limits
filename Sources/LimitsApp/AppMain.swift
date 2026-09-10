import AppKit
import SwiftUI
import Combine
import LimitsCore
import Security

@main
enum LimitsMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check-codex") {
            do {
                let snapshot = try CodexClient.fetch()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        // This process must never raise legacy keychain password/application-trust prompts.
        SecKeychainSetUserInteractionAllowed(false)
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var floatingPanel: NSPanel?
    private var welcomeWindow: NSWindow?
    private var store: UsageStore!
    private var subscriptions = Set<AnyCancellable>()
    private var displayTimer: Timer?
    private var smokeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid duplicate indicators if the app is opened from another copy.
        if !CommandLine.arguments.contains("--smoke-test"), !CommandLine.arguments.contains("--preview-ui"), let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        store = UsageStore()
        popover = NSPopover(); popover.behavior = .transient; popover.animates = true
        popover.contentViewController = NSHostingController(rootView: DashboardView(store: store))
        popover.contentSize = NSSize(width: 356, height: 490)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self; button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Limits — лимиты Codex и Claude")
        }
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &subscriptions)
        store.onFloatingChanged = { [weak self] in self?.updateFloating() }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        displayTimer?.tolerance = 5
        if let index = CommandLine.arguments.firstIndex(of: "--preview-ui"), CommandLine.arguments.count > index + 1 {
            // Render cached readings without changing credentials, preferences or the live cache.
            store.codex.message = nil; store.claude.message = nil
            updateTitle()
            smokeTest(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        updateTitle(); updateFloating(); store.start()
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.store.connection.lock() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.store.connection.lock() }
            }
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 {
            smokeTest(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if CommandLine.arguments.contains("--connect-claude") {
            store.connection.showLogin()
        } else if CommandLine.arguments.contains("--unlock-claude") {
            store.connection.unlock()
        } else if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.togglePopover() }
        } else if CommandLine.arguments.contains("--welcome") || !UserDefaults.standard.bool(forKey: "completedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showWelcome() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if store?.connection.browserLogin.running == true { store.connection.stopLogin() }
    }

    private func updateTitle() {
        guard let button = item?.button else { return }
        let summaries = compactSummaries()
        button.title = ""
        button.image = MenuBarImage.make(summaries)
        button.imagePosition = .imageOnly
        button.toolTip = summaries.map(\.help).joined(separator: "\n\n")
            + "\n\nClaude: 5 часов / неделя. Часы под процентами — время до сброса.\nТочка после процентов означает сохранённые данные."
        button.setAccessibilityValue(summaries.map(\.help).joined(separator: ". "))
    }

    private func compactSummaries() -> [CompactUsage] {
        let now = Date()
        return [CompactUsage(state: store.codex, groupID: store.codexGroup, interval: store.interval, now: now),
                CompactUsage(state: store.claude, claude: true, interval: store.interval, now: now)]
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var installedInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }

    private func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 450),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Limits"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WelcomeView(store: store,
                installedInApplications: installedInApplications) { [weak self] launchAtLogin, floating in
                    guard let self else { return }
                    self.store.floating = floating
                    if launchAtLogin != self.store.launchAtLogin { self.store.setLaunchAtLogin(launchAtLogin) }
                    UserDefaults.standard.set(true, forKey: "completedOnboarding")
                    self.welcomeWindow?.orderOut(nil)
                    self.togglePopover()
                })
            window.center()
            welcomeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateFloating() {
        guard store.floating else { floatingPanel?.orderOut(nil); return }
        if floatingPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 292, height: 65),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FloatingView(store: store, openDashboard: { [weak self] in self?.togglePopover() }))
            if !panel.setFrameUsingName("LimitsFloatingPanel"), let frame = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 312, y: frame.maxY - 85))
            }
            panel.setContentSize(NSSize(width: 292, height: 65))
            panel.setFrameAutosaveName("LimitsFloatingPanel")
            floatingPanel = panel
        }
        if let panel = floatingPanel, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 312, y: screen.visibleFrame.maxY - 85))
        }
        floatingPanel?.orderFrontRegardless()
    }

    private func smokeTest(at directory: URL) {
        let deadline = Date().addingTimeInterval(45)
        smokeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard (!self.store.codex.loading && !self.store.claude.loading) || Date() > deadline else { return }
                timer.invalidate()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try self.render(DashboardView(store: self.store), size: NSSize(width: 356, height: 490),
                                    appearance: .darkAqua, to: directory.appendingPathComponent("panel-dark.png"))
                    try self.render(DashboardView(store: self.store), size: NSSize(width: 356, height: 490),
                                    appearance: .aqua, to: directory.appendingPathComponent("panel-light.png"))
                    try self.render(FloatingView(store: self.store, openDashboard: {}), size: NSSize(width: 292, height: 65),
                                    appearance: .darkAqua, to: directory.appendingPathComponent("floating.png"))
                    if let image = self.item.button?.image {
                        let size = NSSize(width: image.size.width + 16, height: 24)
                        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                            try self.render(Image(nsImage: image).renderingMode(.template).foregroundStyle(Color.primary)
                                .frame(width: size.width, height: size.height).background(.regularMaterial),
                                size: size, appearance: appearance, to: directory.appendingPathComponent("menu-bar-\(name).png"))
                        }
                    }
                    try self.render(ClaudeLoginView(connection: self.store.connection, login: self.store.connection.browserLogin),
                                    size: NSSize(width: 490, height: 445), appearance: .darkAqua, to: directory.appendingPathComponent("claude-login.png"))
                    try self.render(WelcomeView(store: self.store, installedInApplications: true, finish: { _, _ in }),
                                    size: NSSize(width: 520, height: 450), appearance: .darkAqua, to: directory.appendingPathComponent("welcome.png"))
                    let report: [String: Any] = ["codex": self.store.title(for: self.store.codex, groupID: self.store.codexGroup),
                        "codexConnected": self.store.codex.snapshot != nil, "claude": self.store.title(for: self.store.claude),
                        "claudeConnected": self.store.claude.snapshot != nil, "claudeNeedsLogin": self.store.claude.needsLogin,
                        "menuTitle": self.compactSummaries().map { "\($0.name) \($0.value) · \($0.reset)" }.joined(separator: " | "),
                        "codexError": self.store.codex.message ?? "",
                        "claudeError": self.store.claude.message ?? ""]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("smoke-result.json"))
                } catch { fputs("Visual check failed: \(error.localizedDescription)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
    }

    private func render<V: View>(_ root: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw UsageError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw UsageError.invalidResponse }
        try png.write(to: url)
        window.orderOut(nil)
    }
}
