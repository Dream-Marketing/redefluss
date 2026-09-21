import Foundation
import Combine

/// Ein Modell aus dem whisper.cpp-Katalog auf Hugging Face.
public struct CatalogModel: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let note: String
    public let sizeBytes: Int64

    public var fileName: String { "ggml-\(id).bin" }
    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }

    public static let recommended = catalog[0]

    /// Nur mehrsprachige Modelle – die `.en`-Varianten können kein Deutsch.
    public static let catalog: [CatalogModel] = [
        CatalogModel(id: "large-v3-turbo-q5_0", name: "Turbo", note: "Empfohlen · schnell und genau, Deutsch & Englisch", sizeBytes: 574_041_195),
        CatalogModel(id: "large-v3-turbo-q8_0", name: "Turbo (q8)", note: "Etwas genauer, etwas größer", sizeBytes: 874_188_075),
        CatalogModel(id: "large-v3-turbo", name: "Turbo (voll)", note: "Volle Präzision, braucht mehr Speicher", sizeBytes: 1_624_555_275),
        CatalogModel(id: "small-q5_1", name: "Small", note: "Leicht, für ältere Macs", sizeBytes: 190_085_487),
        CatalogModel(id: "base-q5_1", name: "Base", note: "Minimal, deutlich ungenauer", sizeBytes: 59_707_625),
    ]
}

/// Eine Modelldatei auf der Platte.
public struct InstalledModel: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64
    /// Liegt außerhalb des App-Ordners (z. B. ~/.cache/whisper-cpp) – wird nie gelöscht.
    public let isExternal: Bool

    public var fileName: String { (path as NSString).lastPathComponent }

    /// "ggml-large-v3-turbo-q5_0.bin" → "large-v3-turbo-q5_0"
    public var modelID: String {
        var name = (fileName as NSString).deletingPathExtension
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        return name
    }

    public var displayName: String {
        CatalogModel.catalog.first { $0.id == modelID }?.name ?? modelID
    }

    /// Englisch-Modelle (.en) verstehen kein Deutsch.
    public var isEnglishOnly: Bool { modelID.hasSuffix(".en") || modelID.contains(".en-") }
}

public final class ModelManager: NSObject, ObservableObject {
    public static let shared = ModelManager()

    @Published public private(set) var installed: [InstalledModel] = []
    /// Fortschritt 0…1 je Katalog-ID.
    @Published public private(set) var downloads: [String: Double] = [:]
    @Published public private(set) var lastError: String?

    public let modelsDirectory: URL
    /// Weitere Orte, an denen whisper.cpp-Modelle üblicherweise liegen.
    private let externalDirectories: [URL]

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var completions: [String: (Result<InstalledModel, Error>) -> Void] = [:]

    public override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        modelsDirectory = support.appendingPathComponent("Redefluss/Models", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        externalDirectories = [
            home.appendingPathComponent(".cache/whisper-cpp"),
            home.appendingPathComponent(".cache/whisper"),
            home.appendingPathComponent("whisper.cpp/models"),
        ]
        super.init()
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refresh()
    }

    public func refresh() {
        var found: [InstalledModel] = []
        let fm = FileManager.default
        for (directory, external) in [(modelsDirectory, false)] + externalDirectories.map({ ($0, true) }) {
            guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for file in files where file.hasPrefix("ggml-") && file.hasSuffix(".bin") {
                let path = directory.appendingPathComponent(file).path
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                // Unvollständige Dateien und VAD-Modelle ausblenden.
                guard size > 20_000_000, !file.contains("silero") else { continue }
                found.append(InstalledModel(path: path, sizeBytes: size, isExternal: external))
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: CatalogModel.catalog.enumerated().map { ($1.id, $0) })
        found.sort { (rank[$0.modelID] ?? 99, $0.fileName) < (rank[$1.modelID] ?? 99, $1.fileName) }
        let result = found
        DispatchQueue.main.async { self.installed = result }
    }

    public func isInstalled(_ model: CatalogModel) -> InstalledModel? {
        installed.first { $0.modelID == model.id }
    }

    /// Bestes vorhandenes Modell für den Start: zuerst Turbo-Varianten, nie reine Englisch-Modelle.
    public func bestInstalled() -> InstalledModel? {
        installed.first { !$0.isEnglishOnly }
    }

    public func download(_ model: CatalogModel, completion: ((Result<InstalledModel, Error>) -> Void)? = nil) {
        guard tasks[model.id] == nil else { return }
        lastError = nil
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        if let completion { completions[model.id] = completion }
        downloads[model.id] = 0
        task.resume()
    }

    public func cancelDownload(_ model: CatalogModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        completions[model.id] = nil
        downloads[model.id] = nil
    }

    public func delete(_ model: InstalledModel) {
        guard !model.isExternal else { return }
        try? FileManager.default.removeItem(atPath: model.path)
        refresh()
    }

    private func finish(id: String, result: Result<InstalledModel, Error>) {
        DispatchQueue.main.async {
            self.tasks[id] = nil
            self.downloads[id] = nil
            if case .failure(let error) = result, (error as NSError).code != NSURLErrorCancelled {
                self.lastError = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
            self.completions.removeValue(forKey: id)?(result)
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (CatalogModel.catalog.first { $0.id == id }?.sizeBytes ?? 1)
        let progress = min(Double(totalBytesWritten) / Double(expected), 1)
        DispatchQueue.main.async {
            // Nicht jedes Paket neu zeichnen.
            if abs((self.downloads[id] ?? 0) - progress) > 0.004 || progress == 1 {
                self.downloads[id] = progress
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let model = CatalogModel.catalog.first(where: { $0.id == id }) else { return }
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            finish(id: id, result: .failure(URLError(.badServerResponse)))
            return
        }
        let destination = modelsDirectory.appendingPathComponent(model.fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            refresh()
            finish(id: id, result: .success(InstalledModel(path: destination.path, sizeBytes: size, isExternal: false)))
        } catch {
            finish(id: id, result: .failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        finish(id: id, result: .failure(error))
    }
}

public extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
