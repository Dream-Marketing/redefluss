import AVFoundation
import AudioToolbox
import CoreAudio

public enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case engineStart(Error)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Kein Mikrofon gefunden."
        case .converterUnavailable: return "Audioformat des Mikrofons wird nicht unterstützt."
        case .engineStart(let error): return "Aufnahme konnte nicht starten: \(error.localizedDescription)"
        }
    }
}

/// Nimmt das Mikrofon auf und liefert 16-kHz-Mono-Float-Samples, wie Whisper sie erwartet.
/// Pro Aufnahme wird eine frische AVAudioEngine gebaut – das übersteht Gerätewechsel
/// (AirPods rein/raus) ohne Sonderbehandlung.
public final class AudioRecorder {
    public static let sampleRate: Double = 16_000

    /// Pegel 0…1, ca. 20–40× pro Sekunde auf dem Main-Thread.
    public var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var samples: [Float] = []

    public init() {}

    public var isRecording: Bool { engine != nil }

    public func start(deviceUID: String?) throws {
        stopEngine()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceUID, let deviceID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStart(error)
        }
        self.engine = engine
    }

    /// Beendet die Aufnahme und gibt alle Samples zurück.
    public func stop() -> [Float] {
        stopEngine()
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: false)
        return result
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
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
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)
        let chunk = UnsafeBufferPointer(start: channel, count: count)

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(count)).squareRoot()
        // Sprache liegt meist bei -45…-10 dBFS; auf 0…1 abbilden.
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(max((db + 50) / 40, 0), 1)

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}

public struct AudioInputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
