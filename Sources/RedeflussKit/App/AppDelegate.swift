import AppKit
import SwiftUI
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private lazy var controller = DictationController(settings: settings)
    private let navigation = SettingsNavigation()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }

        setUpMainMenu()
        setUpStatusItem()
        controller.onNeedsAttention = { [weak self] tab in self?.showSettings(tab: tab) }
        controller.start()

        controller.$phase
            .combineLatest(controller.$hotkeyActive, controller.$modelState)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        if !settings.onboardingDone {
            showOnboarding()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Doppelklick auf die App im Finder, während sie schon läuft → Einstellungen zeigen.
        showSettings(tab: .general)
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let other = others.first else { return false }
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Menüleiste

    /// Unsichtbares Hauptmenü: Als Menüleisten-App wird es nie angezeigt, aber ohne
    /// „Bearbeiten"-Einträge funktionieren ⌘V/⌘C/⌘A in den eigenen Textfeldern nicht
    /// (auch nicht das eingefügte Diktat im „Probier's aus"-Feld).
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Redefluss beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch controller.phase {
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .idle:
            let ready: Bool
            if case .ready = controller.modelState { ready = true } else { ready = false }
            symbol = controller.hotkeyActive && ready ? "waveform" : "waveform.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Redefluss")
        image?.isTemplate = true
        button.image = image
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !Permissions.accessibilityGranted {
            menu.addItem(item("⚠︎ Bedienungshilfen erlauben …", #selector(openAccessibility)))
        }
        if !Permissions.microphoneGranted {
            menu.addItem(item("⚠︎ Mikrofon erlauben …", #selector(openMicrophone)))
        }
        if case .ready = controller.modelState {} else if case .loading = controller.modelState {} else {
            menu.addItem(item("⚠︎ Sprachmodell einrichten …", #selector(openModelSettings)))
        }
        if Permissions.secureInputActive {
            let secure = NSMenuItem(title: "Sichere Tastatureingabe aktiv – Taste evtl. blockiert", action: nil, keyEquivalent: "")
            secure.isEnabled = false
            menu.addItem(secure)
        }

        menu.addItem(.separator())

        let paste = item("Letztes Diktat einfügen", #selector(pasteLast))
        paste.keyEquivalent = "v"
        paste.keyEquivalentModifierMask = [.command, .control]
        paste.isEnabled = controller.lastTranscript != nil
        menu.addItem(paste)
        let copy = item("Letztes Diktat kopieren", #selector(copyLast))
        copy.isEnabled = controller.lastTranscript != nil
        menu.addItem(copy)

        menu.addItem(.separator())

        let languageMenu = NSMenu()
        for language in SupportedLanguage.all {
            let entry = item(language.name, #selector(selectLanguage(_:)))
            entry.representedObject = language.code
            entry.state = settings.language == language.code ? .on : .off
            languageMenu.addItem(entry)
        }
        let languageItem = NSMenuItem(title: "Sprache", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(item("Verlauf …", #selector(openHistory)))
        let prefs = item("Einstellungen …", #selector(openSettings))
        prefs.keyEquivalent = ","
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = item("Redefluss beenden", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        switch controller.phase {
        case .recording: return "Hört zu …"
        case .transcribing: return "Schreibt …"
        case .idle: break
        }
        switch controller.modelState {
        case .loading(let name): return "Lädt \(name) …"
        case .failed: return "Modell konnte nicht geladen werden"
        case .none: return "Kein Sprachmodell"
        case .ready:
            return controller.hotkeyActive
                ? "Bereit – \(settings.hotkey.shortLabel) halten zum Diktieren"
                : "Diktiertaste inaktiv"
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openMicrophone() {
        if Permissions.microphoneStatus == .notDetermined {
            Permissions.requestMicrophone { _ in }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    @objc private func openModelSettings() { showSettings(tab: .model) }
    @objc private func openHistory() { showSettings(tab: .history) }
    @objc private func openSettings() { showSettings(tab: .general) }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func copyLast() { controller.copyLast() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { settings.language = code }
    }

    // MARK: - Fenster

    public func showSettings(tab: SettingsTab) {
        navigation.tab = tab
        if settingsWindow == nil {
            let view = SettingsView(
                navigation: navigation,
                controller: controller,
                settings: settings,
                models: controller.models,
                history: controller.history,
                onShowOnboarding: { [weak self] in self?.showOnboarding() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Redefluss"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 760, height: 540))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(controller: controller, settings: settings, models: controller.models) { [weak self] in
                self?.settings.onboardingDone = true
                self?.onboardingWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Redefluss einrichten"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
