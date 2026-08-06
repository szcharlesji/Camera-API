import Foundation
import os

/// Owns `Documents/Recordings`. Each recording is a media file plus a JSON
/// sidecar of the same basename, so the catalogue survives app restarts and is
/// also readable straight off an `ifuse` mount.
final class RecordingStore: @unchecked Sendable {
    let directory: URL

    private let log = Logger(subsystem: "cameraapi", category: "store")
    private let lock = NSLock()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    func mediaURL(id: String, container: MediaContainer) -> URL {
        directory.appendingPathComponent("\(id).\(container.rawValue)")
    }

    func metadataURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: - Catalogue

    func save(_ recording: RecordingDTO) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encoder.encode(recording)
            try data.write(to: metadataURL(id: recording.id), options: .atomic)
        } catch {
            log.error("failed to persist metadata for \(recording.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func recording(id: String) -> RecordingDTO? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(id: id)
    }

    func list() -> [RecordingDTO] {
        lock.lock()
        defer { lock.unlock() }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { loadLocked(id: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Reloads the sidecar and refreshes the on-disk size, which is the one field
    /// that can change after the fact (a crash mid-write, a partial delete).
    private func loadLocked(id: String) -> RecordingDTO? {
        let url = metadataURL(id: id)
        guard let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode(RecordingDTO.self, from: data) else {
            return nil
        }
        let mediaPath = directory.appendingPathComponent(stored.filename)
        guard FileManager.default.fileExists(atPath: mediaPath.path) else { return nil }
        let size = fileSize(at: mediaPath)
        guard size != stored.sizeBytes else { return stored }

        return RecordingDTO(
            id: stored.id,
            name: stored.name,
            filename: stored.filename,
            createdAt: stored.createdAt,
            durationSeconds: stored.durationSeconds,
            sizeBytes: size,
            width: stored.width,
            height: stored.height,
            fps: stored.fps,
            codec: stored.codec,
            container: stored.container,
            hasAudio: stored.hasAudio,
            framesWritten: stored.framesWritten,
            framesDropped: stored.framesDropped,
            cameraPosition: stored.cameraPosition,
            rotationDegrees: stored.rotationDegrees
        )
    }

    func mediaURL(for recording: RecordingDTO) -> URL {
        directory.appendingPathComponent(recording.filename)
    }

    // MARK: - Deletion

    @discardableResult
    func delete(id: String) throws -> Int64 {
        guard let recording = recording(id: id) else {
            throw APIError.notFound("No recording with id '\(id)'.")
        }
        lock.lock()
        defer { lock.unlock() }

        let media = directory.appendingPathComponent(recording.filename)
        let freed = fileSize(at: media)
        try? FileManager.default.removeItem(at: media)
        try? FileManager.default.removeItem(at: metadataURL(id: id))
        return freed
    }

    func deleteAll() -> DeleteResultDTO {
        var deleted: [String] = []
        var freed: Int64 = 0
        for recording in list() {
            if let bytes = try? delete(id: recording.id) {
                deleted.append(recording.id)
                freed += bytes
            }
        }
        return DeleteResultDTO(deleted: deleted, freedBytes: freed)
    }

    /// Removes media files with no sidecar and sidecars with no media. These are
    /// the two shapes a crash mid-recording can leave behind.
    func pruneOrphans() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let ids = Set(contents.map { $0.deletingPathExtension().lastPathComponent })
        for id in ids {
            let hasMetadata = FileManager.default.fileExists(atPath: metadataURL(id: id).path)
            let media = contents.first { $0.deletingPathExtension().lastPathComponent == id && $0.pathExtension != "json" }

            if hasMetadata, media == nil {
                try? FileManager.default.removeItem(at: metadataURL(id: id))
                log.notice("pruned metadata without media: \(id, privacy: .public)")
            } else if !hasMetadata, let media {
                try? FileManager.default.removeItem(at: media)
                log.notice("pruned media without metadata: \(id, privacy: .public)")
            }
        }
    }

    // MARK: - Sizes

    func totalBytes() -> Int64 {
        list().reduce(0) { $0 + $1.sizeBytes }
    }

    func freeDiskBytes() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Naming

    /// Strips anything that could escape the recordings directory or confuse a
    /// shell on the Linux side.
    static func sanitize(name: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }
}
