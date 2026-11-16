import Foundation
import Combine

public struct HistoryItem: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable {
        case dictation
        case meeting
    }

    public var id = UUID()
    public let date: Date
    public var text: String
    /// Aufnahmedauer in Sekunden.
    public var audioSeconds: Double
    public let appName: String?
    public var language: String?
    /// nil = Diktat (Einträge älterer Versionen haben das Feld nicht).
    public var kind: Kind?
    /// Meeting wird noch aufgezeichnet bzw. abgeschlossen.
    public var inProgress: Bool?
    /// Dateiname der Audioaufnahme im Aufnahmen-Ordner – nur bei Meetings, wenn das Speichern eingeschaltet war.
    public var audioFile: String?

    public init(date: Date, text: String, audioSeconds: Double, appName: String?, language: String?, kind: Kind? = nil, inProgress: Bool? = nil, audioFile: String? = nil) {
        self.date = date
        self.text = text
        self.audioSeconds = audioSeconds
        self.appName = appName
        self.language = language
        self.kind = kind
        self.inProgress = inProgress
        self.audioFile = audioFile
    }

    public var isMeeting: Bool { kind == .meeting }
}

/// Lokaler Verlauf der Diktate und Meeting-Mitschriften als JSON in Application Support.
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()

    @Published public private(set) var items: [HistoryItem] = []

    /// Hier liegen die Audioaufnahmen der Meetings (nur wenn eingeschaltet); sie gehören zu ihrem Verlaufseintrag.
    public let recordingsDirectory: URL

    private let fileURL: URL
    private let limit = 500

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redefluss", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        recordingsDirectory = base.appendingPathComponent("Aufnahmen", isDirectory: true)
        if let data = try? Data(contentsOf: fileURL) {
            items = Self.decode(data)
        }
        // Ein Meeting, das beim letzten Beenden noch lief, ist jetzt vorbei.
        items = items.map { item in
            var item = item
            if item.inProgress == true { item.inProgress = false }
            return item
        }
    }

    static func decode(_ data: Data) -> [HistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    public var totalWords: Int {
        items.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    public func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > limit {
            items.suffix(items.count - limit).forEach(removeAudio)
            items.removeLast(items.count - limit)
        }
        save()
    }

    /// Ersetzt den Eintrag mit derselben ID (z. B. wachsende Meeting-Mitschrift).
    public func update(_ item: HistoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    /// Löscht den Eintrag und – falls vorhanden – seine Audioaufnahme.
    public func delete(_ item: HistoryItem) {
        removeAudio(of: item)
        items.removeAll { $0.id == item.id }
        save()
    }

    public func clear() {
        items.forEach(removeAudio)
        items.removeAll()
        save()
    }

    /// Audioaufnahme zu einem Eintrag – nil, wenn es keine gibt (oder sie von Hand gelöscht wurde).
    public func audioURL(for item: HistoryItem) -> URL? {
        guard let url = audioLocation(of: item), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Wie viele Einträge haben (noch) eine Audioaufnahme?
    public var recordingCount: Int { items.filter { audioURL(for: $0) != nil }.count }

    private func audioLocation(of item: HistoryItem) -> URL? {
        // Nur der letzte Pfadbestandteil zählt – ein Eintrag darf nie aus dem Ordner herauszeigen.
        guard let name = item.audioFile.map({ ($0 as NSString).lastPathComponent }), !name.isEmpty, name != ".." else { return nil }
        return recordingsDirectory.appendingPathComponent(name)
    }

    private func removeAudio(of item: HistoryItem) {
        guard let url = audioLocation(of: item) else { return }
        try? FileManager.default.removeItem(at: url)
        // Auch die Rohdatei einer laufenden oder abgebrochenen Aufnahme (siehe MeetingAudioWriter).
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pcm"))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
