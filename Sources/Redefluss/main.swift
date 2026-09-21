import AppKit
import RedeflussKit

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "snapshots"
    SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: path))
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
// Menüleisten-App: kein Dock-Symbol, kein Eintrag im App-Umschalter.
app.setActivationPolicy(.accessory)
app.run()
