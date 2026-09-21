import AppKit
import SwiftUI

/// `Redefluss --snapshot <ordner>` rendert die wichtigsten Oberflächen als PNG
/// (für README-Screenshots und zur Sichtprüfung ohne Bildschirmaufnahme-Rechte).
public enum SnapshotRenderer {
    public static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "redefluss.snapshot")!)
        settings.modelPath = ModelManager.shared.bestInstalled()?.path ?? ""
        let controller = DictationController(settings: settings)
        let models = ModelManager.shared
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("redefluss-snapshot"))

        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(controller: controller, settings: settings, models: models, initialStep: step, onFinish: {})
            render(view, size: NSSize(width: 580, height: 480), to: outputDirectory.appendingPathComponent("onboarding-\(step.rawValue).png"))
        }

        let bars: [(String, FlowBarModel.Mode)] = [
            ("idle", .idle),
            ("recording", .recording),
            ("handsfree", .handsFree),
            ("transcribing", .transcribing),
            ("message", .message("Kein Sprachmodell – hier klicken", isError: true)),
        ]
        for (name, mode) in bars {
            let model = FlowBarModel()
            model.mode = mode
            model.levels = [0.1, 0.25, 0.5, 0.8, 0.6, 0.95, 0.7, 0.45, 0.85, 0.55, 0.3, 0.6, 0.2, 0.1]
            let view = FlowBarView(model: model)
                .background(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
            render(view, size: FlowBarPanel.size, to: outputDirectory.appendingPathComponent("flowbar-\(name).png"))
        }

        for tab in [SettingsTab.general, .model, .dictionary] {
            let navigation = SettingsNavigation()
            navigation.tab = tab
            let view = SettingsView(navigation: navigation, controller: controller, settings: settings, models: models, history: history, onShowOnboarding: {})
            render(view, size: NSSize(width: 760, height: 560), to: outputDirectory.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        print("✅ Snapshots in \(outputDirectory.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
