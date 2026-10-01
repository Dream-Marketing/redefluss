import AVFoundation
import CoreAudio

/// Nimmt Systemaudio (alle anderen Programme – also die anderen Teilnehmer) und das Mikrofon
/// gemeinsam auf: ein privates Aggregatgerät aus Ausgabegerät, Mikrofon und einem Prozess-Tap,
/// dessen Eingangsströme zu Mono gemischt und auf 16 kHz gebracht werden.
/// Braucht macOS 14.2 und die Berechtigung „Systemaudioaufnahme" (fragt macOS beim ersten Mal selbst).
@available(macOS 14.2, *)
final class SystemAudioCapture {
    enum Failure: LocalizedError {
        case tap(OSStatus)
        case aggregate(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)
        case format

        var errorDescription: String? {
            switch self {
            case .tap(let status): return "Systemaudio-Tap konnte nicht erstellt werden (\(status))."
            case .aggregate(let status): return "Aufnahmegerät konnte nicht erstellt werden (\(status))."
            case .ioProc(let status): return "Audio-Callback konnte nicht eingerichtet werden (\(status))."
            case .start(let status): return "Aufnahmegerät startet nicht (\(status))."
            case .format: return "Audioformat des Aufnahmegeräts wird nicht unterstützt."
            }
        }
    }

    /// 16-kHz-Mono-Samples, auf einer eigenen Queue.
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var mixFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "redefluss.systemaudio", qos: .userInitiated)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    var isRunning: Bool { procID != nil }

    deinit { stop() }

    /// - Parameter microphoneUID: gewähltes Mikrofon; nil = Systemstandard.
    func start(microphoneUID: String?) throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Redefluss Meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else { throw Failure.tap(tapStatus) }
        tapID = tap

        // Ausgabegerät als Taktgeber (so macht es Apples Beispiel), Mikrofon als zweites Teilgerät.
        let outputUID = AudioDevices.defaultDeviceUID(input: false)
        let micUID = microphoneUID ?? AudioDevices.defaultDeviceUID(input: true)
        var seen = Set<String>()
        let subDevices: [[String: Any]] = [outputUID, micUID].compactMap { $0 }
            .filter { seen.insert($0).inserted }
            .map { [kAudioSubDeviceUIDKey: $0] }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Redefluss Meeting",
            kAudioAggregateDeviceUIDKey: "eu.dream-marketing.redefluss.meeting." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if let outputUID { aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID }

        var device = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggregateStatus == noErr, device != kAudioObjectUnknown else {
            stop()
            throw Failure.aggregate(aggregateStatus)
        }
        aggregateID = device

        guard let rate: Double = CoreAudioProperty.read(device, kAudioDevicePropertyNominalSampleRate), rate > 0,
              Self.inputStreamsAreFloat32(device),
              let mixFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mixFormat, to: targetFormat) else {
            stop()
            throw Failure.format
        }
        self.mixFormat = mixFormat
        self.converter = converter

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard procStatus == noErr, let proc else {
            stop()
            throw Failure.ioProc(procStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(device, proc)
        guard startStatus == noErr else {
            stop()
            throw Failure.start(startStatus)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Erst nach dem Stopp und auf der Audio-Queue freigeben – kein Wettlauf mit einem laufenden Callback.
        queue.sync {
            converter = nil
            mixFormat = nil
        }
    }

    /// Die HAL liefert Aggregatgeräte als Float32; zur Sicherheit trotzdem prüfen.
    private static func inputStreamsAreFloat32(_ device: AudioObjectID) -> Bool {
        guard let streams: [AudioStreamID] = CoreAudioProperty.readArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
              !streams.isEmpty else { return false }
        return streams.allSatisfy { stream in
            guard let format: AudioStreamBasicDescription = CoreAudioProperty.read(stream, kAudioStreamPropertyVirtualFormat) else { return false }
            return format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
        }
    }

    /// Alle Eingangspuffer (Mikrofon-Kanäle + Tap-Stereo) zu Mono summieren, dann auf 16 kHz wandeln.
    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let converter, let mixFormat else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        var frames = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            frames = max(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        guard frames > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(frames)),
              let mix = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        mix.initialize(repeating: 0, count: frames)

        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
            let gain = 1 / Float(channels)
            for frame in 0..<available {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mix[frame] += sum * gain
            }
        }
        for frame in 0..<frames { mix[frame] = max(-1, min(1, mix[frame])) }

        let ratio = targetFormat.sampleRate / mixFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return mono
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }
}
