import SwiftUI
import Combine

/// Einführung beim ersten Start: Berechtigungen, Taste, Modell, Ausprobieren.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, hotkey, model, tryIt
    }

    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    var onFinish: () -> Void

    @State private var step: Step
    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var globeConflict = Permissions.globeKeyConflicts
    @State private var practiceText = ""
    @FocusState private var practiceFocused: Bool
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(controller: DictationController, settings: AppSettings, models: ModelManager, initialStep: Step = .welcome, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings
        self.models = models
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 44)
                .padding(.top, 36)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .id(step)

            HStack {
                StepDots(current: step.rawValue, total: Step.allCases.count)
                Spacer()
                if step != .welcome {
                    Button("Zurück") { go(-1) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle) { primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding(20)
        }
        .frame(width: 580, height: 480)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onReceive(refresh) { _ in
            microphone = Permissions.microphoneGranted
            accessibility = Permissions.accessibilityGranted
            globeConflict = Permissions.globeKeyConflicts
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
                Text("Willkommen bei Redefluss").font(.largeTitle.weight(.semibold))
                Text("Diktiere in jeder App: Taste halten, sprechen, loslassen – der Text steht da, wo dein Cursor ist.\n\nAlles läuft lokal auf deinem Mac. Kein Konto, keine Cloud.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .microphone:
            StepLayout(symbol: "mic.fill", title: "Mikrofon", text: "Redefluss hört nur zu, solange du die Diktiertaste hältst. Die Aufnahme bleibt auf deinem Mac.") {
                PermissionRow(title: "Mikrofonzugriff", granted: microphone, detail: microphone ? "Erlaubt" : "Noch nicht erlaubt") {
                    if Permissions.microphoneStatus == .notDetermined {
                        Permissions.requestMicrophone { microphone = $0 }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }

        case .accessibility:
            StepLayout(symbol: "hand.raised.fill", title: "Bedienungshilfen", text: "Damit Redefluss die Diktiertaste in jeder App erkennt und den Text an der Cursorposition einfügen kann.") {
                PermissionRow(title: "Bedienungshilfen", granted: accessibility, detail: accessibility ? "Erlaubt" : "In den Systemeinstellungen Redefluss einschalten") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                if !accessibility {
                    Text("Steht Redefluss schon in der Liste, ist aber eingeschaltet und funktioniert nicht (z. B. nach einem Update)? Eintrag mit „–“ entfernen und die App neu hinzufügen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .hotkey:
            StepLayout(symbol: "keyboard", title: "Deine Diktiertaste", text: "Halten = diktieren. Mit Taste + Leertaste oder Doppeltipp diktierst du freihändig, Esc verwirft.") {
                Picker("Taste", selection: $settings.hotkey) {
                    ForEach(HotkeyOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.hotkey == .fn && globeConflict {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Die 🌐-Taste ist gerade mit „\(Permissions.globeKeyActionName)“ belegt.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Stell „🌐-Taste drücken für“ auf „Keine Aktion“, sonst öffnet sich das bei jedem Diktat mit.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Tastatur-Einstellungen öffnen") { Permissions.openKeyboardSettings() }
                    }
                    .padding(.top, 6)
                }
                if settings.hotkey == .fn {
                    Text("Fn funktioniert nur auf Apple-Tastaturen. Bei Fremdtastaturen eine der rechten Modifier-Tasten wählen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .model:
            StepLayout(symbol: "cpu", title: "Sprachmodell", text: "Die Spracherkennung (whisper.cpp) braucht ein Modell auf deinem Mac. Einmal laden, danach funktioniert alles offline.") {
                modelStep
            }

        case .tryIt:
            StepLayout(symbol: "waveform", title: "Probier's aus", text: "Klick ins Feld, halte \(settings.hotkey.label) und sag etwas. Loslassen – fertig.") {
                TextEditor(text: $practiceText)
                    .font(.body)
                    .focused($practiceFocused)
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
                    .onAppear { practiceFocused = true }
                if !controller.hotkeyActive {
                    Label("Die Diktiertaste ist noch nicht aktiv – Bedienungshilfen prüfen.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var modelStep: some View {
        let recommended = CatalogModel.recommended
        if let active = models.installed.first(where: { $0.path == settings.modelPath }) {
            Label("\(active.displayName) ist eingerichtet (\(active.sizeBytes.formattedBytes))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if active.isExternal {
                Text("Vorhandenes whisper.cpp-Modell gefunden – es muss nichts heruntergeladen werden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let progress = models.downloads[recommended.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(recommended.name) wird geladen …")
                ProgressView(value: progress)
                Text("\(Int(progress * 100)) % von \(recommended.sizeBytes.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Empfohlen: **\(recommended.name)** (\(recommended.sizeBytes.formattedBytes)) – schnell und genau für Deutsch & Englisch")
                Button("Jetzt herunterladen") {
                    models.download(recommended) { result in
                        if case .success(let file) = result { settings.modelPath = file.path }
                    }
                }
                .buttonStyle(.borderedProminent)
                if let error = models.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Text("Andere Größen findest du später in den Einstellungen unter „Modell“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .microphone: return microphone
        case .model: return !settings.modelPath.isEmpty
        default: return true
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Los geht's"
        case .accessibility where !accessibility: return "Später"
        case .tryIt: return "Fertig"
        default: return "Weiter"
        }
    }

    private func primaryAction() {
        if step == .tryIt {
            onFinish()
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
        if next == .accessibility && !accessibility {
            // Trägt die App schon in die Liste ein, der Nutzer muss nur noch den Schalter umlegen.
            Permissions.promptAccessibility()
        }
    }
}

private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
            Text(title).font(.title.weight(.semibold))
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }
}
