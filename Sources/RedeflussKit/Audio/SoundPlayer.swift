import AppKit

/// Kurze, leise Signaltöne – synthetisch erzeugt, damit sie nicht wie System-Hinweise klingen.
public final class SoundPlayer {
    public enum Cue { case start, stop, error }

    private lazy var startSound = Self.makeSound(notes: [(784, 0.055), (1175, 0.075)], volume: 0.22)
    private lazy var stopSound = Self.makeSound(notes: [(1175, 0.05), (784, 0.07)], volume: 0.18)
    private lazy var errorSound = Self.makeSound(notes: [(330, 0.09), (262, 0.12)], volume: 0.2)

    public init() {}

    public func play(_ cue: Cue) {
        let sound: NSSound?
        switch cue {
        case .start: sound = startSound
        case .stop: sound = stopSound
        case .error: sound = errorSound
        }
        sound?.stop()
        sound?.play()
    }

    /// Baut eine WAV-Datei im Speicher aus Sinustönen mit weicher Hüllkurve.
    private static func makeSound(notes: [(frequency: Double, seconds: Double)], volume: Double) -> NSSound? {
        let sampleRate = 44_100.0
        var pcm: [Int16] = []
        for note in notes {
            let count = Int(sampleRate * note.seconds)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let attack = min(1, Double(i) / (sampleRate * 0.006))
                let release = min(1, Double(count - i) / (sampleRate * 0.03))
                let envelope = attack * release
                // Grundton + leiser Oberton → wärmer als ein reiner Sinus.
                let value = (sin(2 * .pi * note.frequency * t) + 0.25 * sin(4 * .pi * note.frequency * t)) / 1.25
                pcm.append(Int16(max(-1, min(1, value * envelope * volume)) * Double(Int16.max)))
            }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        pcm.forEach { append($0) }
        return NSSound(data: data)
    }
}
