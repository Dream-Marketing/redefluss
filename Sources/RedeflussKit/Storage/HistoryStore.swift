import Foundation
import Combine

public struct HistoryItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public let date: Date
    public let text: String
    /// Aufnahmedauer in Sekunden.
    public let audioSeconds: Double
    public let appName: String?
    public let language: String?
}

/// Lokaler Verlauf der Diktate als JSON in Application Support.
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()

    @Published public private(set) var items: [HistoryItem] = []

    private let fileURL: URL
    private let limit = 500

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redefluss", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
        }
    }

    public var totalWords: Int {
        items.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    public func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    public func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    public func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
