import AVFoundation
import AudioToolbox
import CoreAudio
import RedeflussObjC

public enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case engineStart(Error)
    /// AVFoundation hat eine Objective-C-Exception geworfen (z. B. Gerät weg oder Format gewechselt).
    case engineException(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Kein Mikrofon gefunden."
        case .converterUnavailable: return "Audioformat des Mikrofons wird nicht unterstützt."
        case .engineStart(let error): return "Aufnahme konnte nicht starten: \(error.localizedDescription)"
        case .engineException: return "Mikrofon nicht bereit – bitte noch einmal versuchen."
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
    /// Jeder konvertierte Block (16 kHz Mono), direkt vom Audio-Thread – für fortlaufende Verarbeitung.
    public var onSamples: (([Float]) -> Void)?
    /// Das Eingabegerät hat sich während der Aufnahme geändert (Main-Thread). Die Engine liefert dann nichts mehr.
    public var onInterruption: (() -> Void)?
    /// Samples für `stop()` sammeln. Für lange Mitschnitte ausschalten und stattdessen `onSamples` nutzen.
    public var accumulates = true

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
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
        var thrown: Error?

        // AVFoundation meldet fehlende oder gerade wechselnde Eingabegeräte nicht als Fehler,
        // sondern mit einer NSException („required condition is false: hwFormat“) – die würde
        // die App beenden. Deshalb alles rund um den Engine-Start abfangen.
        let exception = RDFCatchException {
            do {
                try self.configure(engine, deviceUID: deviceUID)
            } catch {
                thrown = error
            }
        }
        if let exception {
            throw AudioRecorderError.engineException(exception.reason ?? exception.name.rawValue)
        }
        if let thrown { throw thrown }

        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            self.onInterruption?()
        }
    }

    private func configure(_ engine: AVAudioEngine, deviceUID: String?) throws {
        let input = engine.inputNode

        if let deviceUID, let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            // Gerät vor der ersten Formatabfrage setzen, sonst rechnet die Engine mit dem Standardgerät.
            try input.auAudioUnit.setDeviceID(deviceID)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }

        // Konverter im Block halten statt als Property lesen – der Tap läuft auf dem Audio-Thread,
        // während `stop()` auf dem Main-Thread aufräumt.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStart(error)
        }
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
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        // Auch das Aufräumen kann eine Exception werfen, wenn das Gerät inzwischen weg ist.
        _ = RDFCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
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
        let level = Self.level(of: chunk)

        if accumulates {
            lock.lock()
            samples.append(contentsOf: chunk)
            lock.unlock()
        }
        onSamples?(Array(chunk))

        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Pegel 0…1 aus dem Effektivwert: Sprache liegt meist bei -45…-10 dBFS.
    public static func level<C: Collection>(of chunk: C) -> Float where C.Element == Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 40, 0), 1)
    }
}

public struct AudioInputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        guard let ids: [AudioDeviceID] = CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = CoreAudioProperty.readString(id, kAudioDevicePropertyDeviceUID),
                  let name = CoreAudioProperty.readString(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// UID des Standard-Eingabe- bzw. -Ausgabegeräts.
    static func defaultDeviceUID(input: Bool) -> String? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id: AudioDeviceID = CoreAudioProperty.read(AudioObjectID(kAudioObjectSystemObject), selector),
              id != kAudioObjectUnknown else { return nil }
        return CoreAudioProperty.readString(id, kAudioDevicePropertyDeviceUID)
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
}

/// Kleine Helfer zum Lesen von CoreAudio-Eigenschaften.
enum CoreAudioProperty {
    static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func readArray<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
