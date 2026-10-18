import Foundation

/// Remembers the records parsed from each log file, keyed by path, so a refresh only re-reads
/// files whose size or modification time changed. Session logs run to gigabytes, so reading
/// them all again every time the window opens is what made Token Stats slow and memory hungry.
final class UsageFileIndex: @unchecked Sendable {
    static let codex = UsageFileIndex(url: supportURL("codex-index-v2.json"), provider: .codex)
    static let claude = UsageFileIndex(url: supportURL("claude-index-v1.json"), provider: .claude)

    private struct Entry: Codable {
        let size: Int64
        let modifiedAt: TimeInterval
        let records: [CachedRecord]
    }

    private struct Stored: Codable {
        let version: Int
        var files: [String: Entry]
    }

    private static let version = 1
    private let url: URL
    private let provider: UsageProvider
    private let lock = NSLock()
    /// Loaded from disk on first use, then kept so later refreshes don't decode it again.
    private var files: [String: Entry]?

    init(url: URL, provider: UsageProvider) {
        self.url = url
        self.provider = provider
    }

    /// Returns every record for `files`, calling `parse` only with the ones that changed.
    /// `parse` returns records keyed by file path.
    func load(files urls: [URL], parse: ([URL]) -> [String: [UsageRecord]]) -> [UsageRecord] {
        lock.lock(); defer { lock.unlock() }
        var files = self.files ?? readFromDisk()
        let stamps = Dictionary(urls.compactMap { url in Self.stamp(url).map { (url.path, $0) } }) { first, _ in first }
        let changed = urls.filter { url in
            guard let stamp = stamps[url.path] else { return false }
            guard let entry = files[url.path] else { return true }
            return entry.size != stamp.size || entry.modifiedAt != stamp.modifiedAt
        }

        var dirty = false
        if !changed.isEmpty {
            let parsed = parse(changed)
            for url in changed {
                guard let stamp = stamps[url.path], let records = parsed[url.path] else { continue }
                files[url.path] = Entry(
                    size: stamp.size,
                    modifiedAt: stamp.modifiedAt,
                    records: records.map { CachedRecord($0, path: url.path) }
                )
                dirty = true
            }
        }
        let before = files.count
        files = files.filter { stamps[$0.key] != nil }
        dirty = dirty || files.count != before

        self.files = files
        if dirty { writeToDisk(files) }
        return files.flatMap { path, entry in entry.records.map { $0.record(path: path, provider: provider) } }
    }

    private static func stamp(_ url: URL) -> (size: Int64, modifiedAt: TimeInterval)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size.int64Value, modified.timeIntervalSinceReferenceDate)
    }

    private func readFromDisk() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.version else { return [:] }
        return stored.files
    }

    private func writeToDisk(_ files: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(Stored(version: Self.version, files: files)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func supportURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Token Stats", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// A record without its file path or provider, saved as a short array to keep the index small.
private struct CachedRecord: Codable {
    let localID: String
    let date: TimeInterval
    let model: String
    let input: Int
    let cached: Int
    let cacheWrite: Int
    let output: Int

    init(_ record: UsageRecord, path: String) {
        let prefix = path + ":"
        localID = record.id.hasPrefix(prefix) ? String(record.id.dropFirst(prefix.count)) : record.id
        date = record.date.timeIntervalSinceReferenceDate
        model = record.model
        input = record.inputTokens
        cached = record.cachedInputTokens
        cacheWrite = record.cacheWriteTokens
        output = record.outputTokens
    }

    func record(path: String, provider: UsageProvider) -> UsageRecord {
        UsageRecord(
            id: "\(path):\(localID)",
            date: Date(timeIntervalSinceReferenceDate: date),
            provider: provider,
            model: model,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteTokens: cacheWrite,
            outputTokens: output
        )
    }

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        localID = try values.decode(String.self)
        date = try values.decode(TimeInterval.self)
        model = try values.decode(String.self)
        input = try values.decode(Int.self)
        cached = try values.decode(Int.self)
        cacheWrite = try values.decode(Int.self)
        output = try values.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(localID)
        try values.encode(date)
        try values.encode(model)
        try values.encode(input)
        try values.encode(cached)
        try values.encode(cacheWrite)
        try values.encode(output)
    }
}

/// Streams a JSONL file in chunks and hands over only the lines containing `marker`, so a
/// multi-gigabyte log never has to fit in memory at once.
enum JSONLReader {
    static func forEachLine(
        at url: URL,
        containing marker: String,
        chunkSize: Int = 1 << 20,
        _ body: (Data) -> Void
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let needle = Array(marker.utf8)
        var pending = Data()

        func emitIfMatching(_ line: UnsafeRawBufferPointer) {
            guard line.count >= needle.count,
                  needle.withUnsafeBytes({ memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) }) != nil
            else { return }
            body(Data(line))
        }

        while true {
            let more = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                // Everything already in `pending` is one unfinished line, so only the new bytes can hold a newline.
                let searchFrom = pending.count
                pending.append(chunk)
                let consumed = pending.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    var start = 0
                    var search = searchFrom
                    while search < bytes.count, let newline = memchr(base + search, 0x0A, bytes.count - search) {
                        let end = base.distance(to: newline)
                        emitIfMatching(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                        start = end + 1
                        search = start
                    }
                    return start
                }
                if consumed > 0 { pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed) }
                return true
            }
            if !more { break }
        }
        if !pending.isEmpty { pending.withUnsafeBytes { emitIfMatching($0) } }
    }
}
