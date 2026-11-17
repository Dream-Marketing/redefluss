enum VoiceProcessingPolicy {
    static let macCallBundleID = "com.apple.avconferenced"

    static func isNeeded(for users: [MicrophoneUser]) -> Bool {
        users.contains { $0.bundleID == macCallBundleID }
    }
}
