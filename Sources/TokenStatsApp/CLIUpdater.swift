import Foundation

/// One agent CLI and how to update it.
struct CLITool: Equatable, Sendable {
    let name: String
    let executable: URL
    let update: [String]
    /// Prints the newest released version without installing anything. When it matches the
    /// installed one the update is skipped, because npm reinstalls a package even at the same
    /// version, and that swaps files out from under any Codex that's running.
    var latestVersion: [String]? = nil
    var environment: [String: String] = [:]
    var versionEnvironment: [String: String] = [:]

    /// Works out how to update each installed CLI. Ones that aren't installed, or that
    /// something else keeps up to date (Codex inside ChatGPT.app), are left out.
    static func installed(find: (String) -> URL? = CommandLocator.find) -> [CLITool] {
        var tools: [CLITool] = []
        if let claude = find("claude") {
            tools.append(CLITool(name: "claude", executable: claude, update: [claude.path, "update"]))
        }
        if let codex = find("codex"), !codex.path.contains(".app/") {
            let npm = codex.deletingLastPathComponent().appendingPathComponent("npm")
            if FileManager.default.isExecutableFile(atPath: npm.path) {
                tools.append(CLITool(
                    name: "codex", executable: codex, update: [npm.path, "install", "-g", "@openai/codex@latest"],
                    latestVersion: [npm.path, "view", "@openai/codex@latest", "version"]
                ))
            }
        }
        if let grok = find("grok") {
            tools.append(CLITool(name: "grok", executable: grok, update: [grok.path, "update"]))
        }
        if let muse = find("muse") {
            // The launcher installs the latest build and exits when asked to; it never starts a session.
            tools.append(CLITool(
                name: "muse", executable: muse, update: [muse.path],
                environment: ["MUSE_LAUNCHER_INSTALL": "1"],
                versionEnvironment: ["MUSE_NO_AUTO_UPDATE": "1"]
            ))
        }
        return tools
    }

    /// Pulls the version number out of `--version` output such as "codex-cli 0.163.0" or "2.1.302 (Claude Code)".
    static func version(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }
}

struct CLIUpdateResult: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let before: String?
    let after: String?
    let succeeded: Bool
    let detail: String

    var summary: String {
        if !succeeded { return "\(name): update failed" }
        if let before, let after, before != after { return "\(name) \(before) → \(after)" }
        return "\(name) \(after ?? before ?? "") up to date"
    }
}

/// Updates Claude Code, Codex, Grok and Muse once a day while Token Stats is running.
@MainActor
final class CLIUpdater: ObservableObject {
    static let shared = CLIUpdater()
    nonisolated static let interval: TimeInterval = 24 * 60 * 60

    @Published private(set) var isUpdating = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var results: [CLIUpdateResult] = []
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    nonisolated private enum Keys {
        static let enabled = "cliUpdates.enabled"
        static let lastRun = "cliUpdates.lastRun"
        static let results = "cliUpdates.results"
    }

    private var timer: Timer?

    var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Stats/cli-updates.log")
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        lastRun = defaults.object(forKey: Keys.lastRun) as? Date
        if let data = defaults.data(forKey: Keys.results) {
            results = (try? JSONDecoder().decode([CLIUpdateResult].self, from: data)) ?? []
        }
    }

    func start() {
        guard timer == nil else { return }
        runIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in CLIUpdater.shared.runIfDue() }
        }
    }

    nonisolated static func isDue(lastRun: Date?, now: Date = Date()) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    func runIfDue() {
        if isEnabled, Self.isDue(lastRun: lastRun) { updateNow() }
    }

    func updateNow() {
        guard !isUpdating else { return }
        isUpdating = true
        let logURL = logURL
        Task {
            let results = await Task.detached { Self.updateAll(logURL: logURL) }.value
            self.results = results
            lastRun = Date()
            Self.record(results, at: lastRun!)
            isUpdating = false
        }
    }

    nonisolated static func record(_ results: [CLIUpdateResult], at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: Keys.lastRun)
        UserDefaults.standard.set(try? JSONEncoder().encode(results), forKey: Keys.results)
    }

    /// Runs a command with extra environment and a timeout; a seam so tests can fake the CLIs.
    typealias CommandRunner = @Sendable (_ command: [String], _ environment: [String: String], _ timeout: TimeInterval) -> (status: Int32, output: String)

    nonisolated static let processRunner: CommandRunner = { ProcessRunner.run($0, environment: $1, timeout: $2) }

    /// Runs one after another so two package managers never fight over PATH or locks.
    nonisolated static func updateAll(logURL: URL) -> [CLIUpdateResult] {
        var log = "\n== \(Date().formatted(.iso8601))\n"
        let results = CLITool.installed().map { tool -> CLIUpdateResult in
            let (result, entry) = update(tool)
            log += entry
            return result
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(log.utf8))
            try? handle.close()
        } else {
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
        }
        return results
    }

    /// Updates one CLI and returns its result plus its entry for `cli-updates.log`.
    nonisolated static func update(_ tool: CLITool, run: CommandRunner = processRunner) -> (result: CLIUpdateResult, log: String) {
        let before = currentVersion(tool, run: run)
        // If the check fails (offline, registry error) this falls through to the update, as before.
        if let check = tool.latestVersion, let before,
           case let latest = run(check, tool.environment, 60), latest.status == 0,
           CLITool.version(from: latest.output) == before {
            return (
                CLIUpdateResult(name: tool.name, before: before, after: before, succeeded: true, detail: "Already up to date (\(before))"),
                "-- \(tool.name): \(before) is the latest, install skipped\n"
            )
        }
        let updated = run(tool.update, tool.environment, 10 * 60)
        let after = currentVersion(tool, run: run)
        return (
            CLIUpdateResult(
                name: tool.name, before: before, after: after, succeeded: updated.status == 0,
                detail: String(updated.output.split(separator: "\n").last ?? "")
            ),
            "-- \(tool.name): \(before ?? "?") -> \(after ?? "?") (exit \(updated.status))\n\(updated.output.suffix(2000))\n"
        )
    }

    nonisolated private static func currentVersion(_ tool: CLITool, run: CommandRunner) -> String? {
        CLITool.version(from: run([tool.executable.path, "--version"], tool.versionEnvironment, 60).output)
    }
}

enum ProcessRunner {
    /// Runs a command with the user's tool folders on PATH and returns its exit status and combined output.
    static func run(_ command: [String], environment extra: [String: String] = [:], input: Data? = nil, timeout: TimeInterval) -> (status: Int32, output: String) {
        guard let first = command.first else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(command.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ([URL(fileURLWithPath: first).deletingLastPathComponent().path, "\(home)/.local/bin",
                                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        extra.forEach { environment[$0] = $1 }
        process.environment = environment
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
