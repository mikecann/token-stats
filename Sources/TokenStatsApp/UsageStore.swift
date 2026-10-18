import AppKit
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    /// One store for the whole app, so closing and reopening the window keeps what's loaded.
    static let shared = UsageStore()

    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    @Published var errorMessage: String?
    @Published private(set) var openRouterFileName: String?
    @Published private(set) var openRouterAPIStatus = "Not connected"
    @Published private(set) var openRouterAPIRecordCount = 0

    private let fileManager = FileManager.default
    private let openRouterBookmarkKey = "tokenStats.openRouterCSVBookmark"

    init() {
        restoreOpenRouterBookmarkName()
        if OpenRouterKeychain.read() != nil {
            openRouterAPIStatus = "Connecting…"
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let bookmark = UserDefaults.standard.data(forKey: openRouterBookmarkKey)
        let managementKey = OpenRouterKeychain.read()
        openRouterAPIStatus = managementKey == nil ? "Not connected" : "Refreshing…"

        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                await UsageLoader.loadAll(
                    openRouterBookmark: bookmark,
                    openRouterManagementKey: managementKey
                )
            }.value
            records = loaded.records.sorted { $0.date < $1.date }
            errorMessage = loaded.errors.isEmpty ? nil : loaded.errors.joined(separator: "\n")
            openRouterAPIRecordCount = loaded.openRouterAPIRecordCount
            if managementKey == nil {
                openRouterAPIStatus = "Not connected"
            } else if let apiError = loaded.openRouterAPIError {
                openRouterAPIStatus = "Connection failed"
                errorMessage = ([errorMessage, "OpenRouter: \(apiError)"])
                    .compactMap { $0 }
                    .joined(separator: "\n")
            } else {
                openRouterAPIStatus = "API connected"
            }
            lastRefresh = Date()
            isLoading = false
        }
    }

    func chooseOpenRouterCSV() {
        let panel = NSOpenPanel()
        panel.title = "Choose OpenRouter Activity CSV"
        panel.message = "Export CSV from openrouter.ai/activity, then choose it here."
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: openRouterBookmarkKey)
            openRouterFileName = url.lastPathComponent
            refresh()
        } catch {
            errorMessage = "Could not remember that OpenRouter export: \(error.localizedDescription)"
        }
    }

    func removeOpenRouterCSV() {
        UserDefaults.standard.removeObject(forKey: openRouterBookmarkKey)
        openRouterFileName = nil
        refresh()
    }

    func connectOpenRouterAPI() {
        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        keyField.placeholderString = "OpenRouter management key"

        let alert = NSAlert()
        alert.messageText = "Connect OpenRouter"
        alert.informativeText = "Paste a management key. Token Stats stores it in your macOS Keychain and uses it only for the read-only Activity API."
        alert.accessoryView = keyField
        alert.addButton(withTitle: "Save key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try OpenRouterKeychain.save(keyField.stringValue)
            refresh()
        } catch {
            errorMessage = "Could not save the OpenRouter key: \(error.localizedDescription)"
        }
    }

    func disconnectOpenRouterAPI() {
        OpenRouterKeychain.delete()
        openRouterAPIStatus = "Not connected"
        openRouterAPIRecordCount = 0
        refresh()
    }

    private func restoreOpenRouterBookmarkName() {
        guard let data = UserDefaults.standard.data(forKey: openRouterBookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            openRouterFileName = url.lastPathComponent
        }
    }
}

/// `token-stats usage` reads the local logs the way the window does and prints the totals.
enum UsageCommand {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().first == "--usage" else { return }
        let started = Date()
        Task.detached {
            let loaded = await UsageLoader.loadAll(openRouterBookmark: nil, openRouterManagementKey: nil)
            let start = DashboardRange.thirtyDays.startDate(relativeTo: Date(), records: [])
            for provider in [UsageProvider.claude, .codex] {
                let all = loaded.records.filter { $0.provider == provider }
                let recent = all.filter { $0.date >= start }
                print("\(provider.rawValue): \(all.count.formatted()) records, \(TokenFormat.compact(recent.reduce(0) { $0 + $1.totalTokens })) tokens in the last 30 days")
            }
            print(String(format: "Read in %.1fs", Date().timeIntervalSince(started)))
            exit(0)
        }
        RunLoop.main.run()
    }
}

private enum UsageLoader {
    struct Result {
        let records: [UsageRecord]
        let errors: [String]
        let openRouterAPIRecordCount: Int
        let openRouterAPIError: String?
    }

    static func loadAll(
        openRouterBookmark: Data?,
        openRouterManagementKey: String?
    ) async -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var records: [UsageRecord] = []
        var errors: [String] = []
        var openRouterCSVRecords: [UsageRecord] = []

        let codexDirectories = [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions")
        ]
        let codexFiles = codexDirectories.flatMap { jsonlFiles(under: $0) }
        // Replaced by codex-index-v2.json, which shares its format with the Claude index.
        try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/Token Stats/codex-index-v1.json"))
        records += UsageFileIndex.codex.load(files: codexFiles) { changed in
            // The app is most often launched alongside Codex, which bundles
            // ripgrep. Keep a pure Swift fallback so the tool still works if
            // that binary moves or is unavailable.
            let grouped = RipgrepCodexLogReader.relevantLinesByFile(files: changed)
            return Dictionary(uniqueKeysWithValues: changed.map { url in
                let lines = grouped.map { $0[url.path] ?? [] } ?? StreamingCodexLogReader.relevantLines(at: url)
                return (url.path, CodexUsageParser.parse(lines: lines, sourceID: url.path))
            })
        }

        let claudeDirectory = home.appendingPathComponent(".claude/projects")
        records += UsageFileIndex.claude.load(files: jsonlFiles(under: claudeDirectory)) { changed in
            parallelMap(changed) { ClaudeUsageParser.parse(fileAt: $0) }
        }

        if let bookmark = openRouterBookmark {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let csv = try String(contentsOf: url, encoding: .utf8)
                openRouterCSVRecords = try OpenRouterCSVParser.parse(
                    csv: csv,
                    sourceID: url.path
                )
            } catch {
                errors.append("OpenRouter: \(error.localizedDescription)")
            }
        }

        var openRouterAPIRecords: [UsageRecord] = []
        var openRouterAPIError: String?
        if let openRouterManagementKey {
            do {
                openRouterAPIRecords = try await OpenRouterActivityClient.fetch(
                    managementKey: openRouterManagementKey
                )
            } catch {
                openRouterAPIError = error.localizedDescription
            }
        }

        // A historical CSV can overlap the API's rolling window. Prefer the
        // API for days it returned so importing a CSV never doubles spend.
        let calendar = Calendar(identifier: .gregorian)
        let apiDays = Set(openRouterAPIRecords.map {
            calendar.startOfDay(for: $0.date)
        })
        records += openRouterCSVRecords.filter {
            !apiDays.contains(calendar.startOfDay(for: $0.date))
        }
        records += openRouterAPIRecords

        return Result(
            records: records,
            errors: errors,
            openRouterAPIRecordCount: openRouterAPIRecords.count,
            openRouterAPIError: openRouterAPIError
        )
    }

    private static func jsonlFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    /// Parses files on every core. The first run reads every session log there is.
    private static func parallelMap(_ urls: [URL], _ transform: (URL) -> [UsageRecord]) -> [String: [UsageRecord]] {
        var results = [[UsageRecord]](repeating: [], count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let parsed = autoreleasepool { transform(urls[index]) }
            lock.lock(); results[index] = parsed; lock.unlock()
        }
        return Dictionary(uniqueKeysWithValues: zip(urls.map(\.path), results))
    }
}

private enum RipgrepCodexLogReader {
    static func relevantLinesByFile(files: [URL]) -> [String: [String]]? {
        guard let executable = executableURL() else { return nil }
        let existingFiles = files.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingFiles.isEmpty else { return [:] }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--with-filename",
            "--no-heading",
            "-g", "*.jsonl",
            "-e", #""type":"token_count""#,
            "-e", #""type":"turn_context""#
        ] + existingFiles.map(\.path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            var grouped: [String: [String]] = [:]
            for outputLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let separator = outputLine.range(of: ":{") else { continue }
                let path = String(outputLine[..<separator.lowerBound])
                let json = "{" + outputLine[separator.upperBound...]
                grouped[path, default: []].append(String(json))
            }
            return grouped
        } catch {
            return nil
        }
    }

    private static func executableURL() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/rg",
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg"
        ]
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }
}

private enum StreamingCodexLogReader {
    private enum LineKind {
        case tokenCount
        case turnContext

        var captureLimit: Int {
            switch self {
            case .tokenCount: return 128 * 1_024
            case .turnContext: return 8 * 1_024
            }
        }
    }

    private static let tokenMarker = Data(#""type":"token_count""#.utf8)
    private static let contextMarker = Data(#""type":"turn_context""#.utf8)
    private static let probeLimit = 1_024

    static func relevantLines(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var result: [String] = []
        var probe = Data()
        var captured = Data()
        var kind: LineKind?
        var decided = false

        func detectKind(in data: Data) -> LineKind? {
            if data.range(of: tokenMarker) != nil { return .tokenCount }
            if data.range(of: contextMarker) != nil { return .turnContext }
            return nil
        }

        func consume(_ segment: Data) {
            var offset = 0
            if !decided {
                let needed = max(0, probeLimit - probe.count)
                let amount = min(needed, segment.count)
                if amount > 0 {
                    probe.append(segment.prefix(amount))
                    offset = amount
                }
                if let detected = detectKind(in: probe) {
                    kind = detected
                    decided = true
                    captured = probe
                } else if probe.count >= probeLimit {
                    decided = true
                }
            }

            guard let kind, offset < segment.count else { return }
            let remainingCapacity = max(0, kind.captureLimit - captured.count)
            guard remainingCapacity > 0 else { return }
            captured.append(segment.dropFirst(offset).prefix(remainingCapacity))
        }

        func finishLine() {
            if !decided, let detected = detectKind(in: probe) {
                kind = detected
                captured = probe.prefix(detected.captureLimit)
            }
            if kind != nil, let line = String(data: captured, encoding: .utf8) {
                result.append(line)
            }
            probe.removeAll(keepingCapacity: true)
            captured.removeAll(keepingCapacity: true)
            kind = nil
            decided = false
        }

        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            var start = chunk.startIndex
            while start < chunk.endIndex {
                if let newline = chunk[start...].firstIndex(of: 0x0A) {
                    consume(Data(chunk[start..<newline]))
                    finishLine()
                    start = chunk.index(after: newline)
                } else {
                    consume(Data(chunk[start...]))
                    break
                }
            }
        }
        if !probe.isEmpty || !captured.isEmpty { finishLine() }
        return result
    }
}
