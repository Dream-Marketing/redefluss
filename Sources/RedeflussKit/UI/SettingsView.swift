import SwiftUI
import Combine
import ServiceManagement
import AVFoundation

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general, model, dictionary, history, about
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .model: return "Modell"
        case .dictionary: return "Wörterbuch"
        case .history: return "Verlauf"
        case .about: return "Info"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cpu"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    @ObservedObject var history: HistoryStore
    var onShowOnboarding: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $navigation.tab) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(170)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigation.tab {
                case .general: GeneralPane(controller: controller, settings: settings, onShowOnboarding: onShowOnboarding)
                case .model: ModelPane(controller: controller, settings: settings, models: models)
                case .dictionary: DictionaryPane(settings: settings)
                case .history: HistoryPane(history: history)
                case .about: AboutPane(history: history)
                }
            }
            .navigationTitle(navigation.tab.title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - Allgemein

private struct GeneralPane: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    var onShowOnboarding: () -> Void
    @State private var devices: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var microphone = Permissions.microphoneGranted
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !accessibility || !microphone {
                Section {
                    PermissionRow(title: "Mikrofon", granted: microphone, detail: "Damit Redefluss dich hören kann.") {
                        if Permissions.microphoneStatus == .notDetermined {
                            Permissions.requestMicrophone { microphone = $0 }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                    PermissionRow(title: "Bedienungshilfen", granted: accessibility, detail: "Für die Diktiertaste und das Einfügen von Text.") {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                } header: {
                    Text("Berechtigungen fehlen")
                }
            }

            Section("Tastenkürzel") {
                Picker("Diktiertaste", selection: $settings.hotkey) {
                    ForEach(HotkeyOption.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Freihand-Modus (Taste + Leertaste oder Doppeltipp)", isOn: $settings.handsFreeEnabled)
                LabeledContent("Letztes Diktat einfügen") { Text("⌃⌘V").foregroundStyle(.secondary) }
                if settings.hotkey == .fn && Permissions.globeKeyConflicts {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Die 🌐-Taste öffnet gerade „\(Permissions.globeKeyActionName)“.")
                            Text("Stell in den Tastatur-Einstellungen „🌐-Taste drücken für“ auf „Keine Aktion“.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            Button("Tastatur-Einstellungen öffnen") { Permissions.openKeyboardSettings() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            Section("Sprache & Mikrofon") {
                Picker("Sprache", selection: $settings.language) {
                    ForEach(SupportedLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Mikrofon", selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Systemstandard").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
            }

            Section("Text") {
                Toggle("Füllwörter entfernen (äh, ähm, uh …)", isOn: $settings.removeFillers)
                Toggle("Leerzeichen nach dem Diktat anhängen", isOn: $settings.appendTrailingSpace)
                Toggle("Zwischenablage nach dem Einfügen wiederherstellen", isOn: $settings.restoreClipboard)
            }

            Section {
                Toggle("Meetings automatisch mitschreiben", isOn: $settings.meetingAutoRecord)
                    .disabled(!MeetingDetector.isSupported)
                Toggle("Andere Teilnehmer mitschreiben (Systemaudio)", isOn: $settings.meetingSystemAudio)
                    .disabled(!MeetingDetector.isSupported || !settings.meetingAutoRecord)
                if !MeetingDetector.isSupported {
                    Text("Braucht macOS 14.2 oder neuer.").font(.callout).foregroundStyle(.secondary)
                } else {
                    meetingStatus
                }
                if let problem = controller.meeting.systemAudioProblem {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Systemaudio ließ sich zuletzt nicht aufnehmen – es wurde nur das Mikrofon mitgeschrieben.")
                            Text(problem).font(.callout).foregroundStyle(.secondary)
                            Button("Berechtigung „Systemaudioaufnahme“ prüfen") { Permissions.openAudioCaptureSettings() }
                                .buttonStyle(.link)
                        }
                    }
                }
            } header: {
                Text("Meetings")
            } footer: {
                Footnote("Sobald eine andere App (Zoom, Teams, FaceTime, der Browser …) das Mikrofon nutzt, schreibt Redefluss das Gespräch mit und legt den Text im Verlauf ab – nichts wird eingefügt, kein Audio gespeichert. Beim ersten Mal fragt macOS nach der Erlaubnis für Systemaudio. Teilnehmende vorher informieren.")
            }

            Section("Darstellung & System") {
                Toggle("Töne bei Start und Ende", isOn: $settings.playSounds)
                Toggle("Leiste auch im Ruhezustand zeigen", isOn: $settings.showIdlePill)
                LabeledContent("Leiste verschieben") {
                    HStack {
                        Text(settings.flowBarPosition == nil ? "Unten mittig (ziehen zum Verschieben)" : "Eigene Position")
                            .foregroundStyle(.secondary)
                        if settings.flowBarPosition != nil {
                            Button("Zurücksetzen") { settings.flowBarPosition = nil }
                        }
                    }
                }
                Toggle("Diktate im Verlauf speichern", isOn: $settings.saveHistory)
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.callout).foregroundStyle(.red)
                }
                Button("Einführung erneut zeigen") { onShowOnboarding() }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
        .onReceive(refresh) { _ in
            accessibility = Permissions.accessibilityGranted
            microphone = Permissions.microphoneGranted
        }
    }

    @ViewBuilder
    private var meetingStatus: some View {
        switch controller.meeting.state {
        case .recording(let appName, _):
            Label("Mitschrift läuft: \(appName)", systemImage: "record.circle").foregroundStyle(.red)
        case .finishing:
            Label("Mitschrift wird gespeichert …", systemImage: "ellipsis.circle").foregroundStyle(.secondary)
        case .idle:
            if !settings.meetingAutoRecord {
                Text("Aus – im Menüleisten-Symbol lässt sich eine Mitschrift auch von Hand starten.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if controller.microphoneUsers.isEmpty {
                Text("Gerade nutzt keine andere App das Mikrofon.").font(.callout).foregroundStyle(.secondary)
            } else {
                let names = Array(Set(controller.microphoneUsers.map(\.name))).sorted().joined(separator: ", ")
                Label("Mikrofon in Benutzung: \(names) – Mitschrift startet gleich", systemImage: "mic.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Ging nicht: \(error.localizedDescription). Liegt die App im Programme-Ordner?"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Erlauben", action: action)
            }
        }
    }
}

// MARK: - Modell

private struct ModelPane: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager

    var body: some View {
        Form {
            Section {
                HStack {
                    statusIcon
                    Text(statusText)
                    Spacer()
                }
            } header: {
                Text("Aktives Modell")
            } footer: {
                Footnote("Alles läuft lokal über whisper.cpp mit Metal-Beschleunigung. Kein Konto, keine Cloud – dein Audio verlässt den Mac nie.")
            }

            Section("Auf diesem Mac") {
                if models.installed.isEmpty {
                    Text("Noch kein Modell vorhanden – lade unten eins herunter.").foregroundStyle(.secondary)
                }
                ForEach(models.installed) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text("\(model.fileName) · \(model.sizeBytes.formattedBytes)\(model.isExternal ? " · gefunden in \(shortDirectory(model.path))" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.isEnglishOnly {
                                Text("Nur Englisch").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if settings.modelPath == model.path {
                            Text("Aktiv").font(.callout.weight(.medium)).foregroundStyle(.green)
                        } else {
                            Button("Verwenden") { settings.modelPath = model.path }
                        }
                        if !model.isExternal {
                            Button(role: .destructive) {
                                if settings.modelPath == model.path { settings.modelPath = "" }
                                models.delete(model)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Löschen")
                        }
                    }
                }
            }

            Section {
                ForEach(CatalogModel.catalog) { model in
                    let installed = models.isInstalled(model)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                            Text("\(model.note) · \(model.sizeBytes.formattedBytes)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let progress = models.downloads[model.id] {
                            ProgressView(value: progress).frame(width: 110)
                            Text("\(Int(progress * 100)) %").monospacedDigit().frame(width: 40, alignment: .trailing)
                            Button { models.cancelDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        } else if installed != nil {
                            Text("Vorhanden").foregroundStyle(.secondary)
                        } else {
                            Button("Laden") {
                                models.download(model) { result in
                                    if case .success(let file) = result, settings.modelPath.isEmpty {
                                        settings.modelPath = file.path
                                    }
                                }
                            }
                        }
                    }
                }
                if let error = models.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Herunterladen")
            } footer: {
                Footnote("Quelle: huggingface.co/ggerganov/whisper.cpp")
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.modelState {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .none: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch controller.modelState {
        case .ready(let name): return "\(name) ist bereit"
        case .loading(let name): return "\(name) wird geladen …"
        case .failed(let message): return message
        case .none: return "Kein Modell ausgewählt"
        }
    }

    private func shortDirectory(_ path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Wörterbuch

private struct DictionaryPane: View {
    @ObservedObject var settings: AppSettings
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Neues Wort, z. B. Vorenza", text: $newWord)
                        .onSubmit(addWord)
                    Button("Hinzufügen", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.dictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { settings.dictionary.removeAll { $0 == word } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Eigene Wörter")
            } footer: {
                Footnote("Namen, Marken und Fachbegriffe, die Whisper richtig schreiben soll. Sie werden als Hinweis mitgegeben.")
            }

            Section {
                HStack {
                    TextField("Gesagt", text: $newFrom)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Geschrieben", text: $newTo)
                        .onSubmit(addReplacement)
                    Button("Hinzufügen", action: addReplacement)
                        .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.replacements) { replacement in
                    HStack {
                        Text(replacement.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(replacement.to)
                        Spacer()
                        Button { settings.replacements.removeAll { $0.id == replacement.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Ersetzungen")
            } footer: {
                Footnote("Wird nach der Transkription ersetzt (ganze Wörter, Groß-/Kleinschreibung egal) – z. B. „mfg“ → „Mit freundlichen Grüßen“.")
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !settings.dictionary.contains(word) else { return }
        settings.dictionary.append(word)
        newWord = ""
    }

    private func addReplacement() {
        let from = newFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return }
        settings.replacements.append(Replacement(from: from, to: newTo))
        newFrom = ""
        newTo = ""
    }
}

// MARK: - Verlauf

private struct HistoryPane: View {
    @ObservedObject var history: HistoryStore
    @State private var search = ""
    @State private var copiedID: UUID?
    @State private var expanded: Set<UUID> = []

    private var filtered: [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.items }
        return history.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if history.items.isEmpty {
                ContentUnavailableView("Noch keine Diktate", systemImage: "waveform", description: Text("Halte die Diktiertaste und sprich – hier erscheint alles, was du diktiert hast, und die Mitschriften deiner Meetings."))
            } else {
                List {
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            if item.isMeeting {
                                HStack(spacing: 6) {
                                    Image(systemName: item.inProgress == true ? "record.circle" : "person.2.fill")
                                        .foregroundStyle(item.inProgress == true ? .red : .secondary)
                                    Text(item.inProgress == true ? "Meeting · läuft noch" : "Meeting · \(MeetingRecorder.clock(item.audioSeconds))")
                                        .font(.callout.weight(.medium))
                                }
                            }
                            if item.text.isEmpty {
                                Text(item.inProgress == true ? "Noch nichts erkannt …" : "Nichts erkannt")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(item.text)
                                    .textSelection(.enabled)
                                    .lineLimit(item.isMeeting && !expanded.contains(item.id) ? 6 : nil)
                            }
                            if item.isMeeting, item.text.count > 400 {
                                Button(expanded.contains(item.id) ? "Weniger anzeigen" : "Ganze Mitschrift anzeigen") {
                                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                            HStack(spacing: 6) {
                                Text(item.date, format: .dateTime.day().month().hour().minute())
                                if let app = item.appName { Text("· \(app)") }
                                if let language = item.language { Text("· \(language.uppercased())") }
                                Spacer()
                                Button(copiedID == item.id ? "Kopiert" : "Kopieren") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.text, forType: .string)
                                    copiedID = item.id
                                }
                                .buttonStyle(.link)
                                Button { history.delete(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .searchable(text: $search, placement: .toolbar, prompt: "Verlauf durchsuchen")
                .toolbar {
                    Button("Alles löschen", role: .destructive) { history.clear() }
                }
            }
        }
    }
}

// MARK: - Info

private struct AboutPane: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Redefluss").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Lokales Diktieren für macOS – Taste halten, sprechen, loslassen.\nTranskription mit whisper.cpp direkt auf deinem Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !history.items.isEmpty {
                Text("\(history.items.count) Diktate · \(history.totalWords) Wörter bisher")
                    .font(.callout)
                    .padding(.top, 6)
            }
            Link("Projekt auf GitHub", destination: URL(string: "https://github.com/Dream-Marketing/redefluss")!)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
