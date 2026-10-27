import XCTest
@testable import TokenStatsApp

final class CLIUpdaterTests: XCTestCase {
    func testVersionParsingHandlesEachCLIsFormat() {
        XCTAssertEqual(CLITool.version(from: "2.1.302 (Claude Code)"), "2.1.302")
        XCTAssertEqual(CLITool.version(from: "codex-cli 0.163.0\n"), "0.163.0")
        XCTAssertEqual(CLITool.version(from: "codex-cli 0.162.0-alpha.17.2"), "0.162.0-alpha.17.2")
        XCTAssertEqual(CLITool.version(from: "muse 1.4.9-R6297.1"), "1.4.9-R6297.1")
        XCTAssertNil(CLITool.version(from: "command not found"))
    }

    func testUpdatesAreDueOncePerDay() {
        let now = Date()
        XCTAssertTrue(CLIUpdater.isDue(lastRun: nil, now: now))
        XCTAssertFalse(CLIUpdater.isDue(lastRun: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(CLIUpdater.isDue(lastRun: now.addingTimeInterval(-24 * 3600), now: now))
    }

    func testInstalledBuildsUpdateCommandsAndSkipsBundledCodex() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        for name in ["codex", "npm"] {
            let file = bin.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let paths = [
            "claude": URL(fileURLWithPath: "/u/.local/bin/claude"),
            "codex": bin.appendingPathComponent("codex"),
            "muse": URL(fileURLWithPath: "/u/.local/bin/muse")
        ]

        let tools = CLITool.installed { paths[$0] }

        XCTAssertEqual(tools.map(\.name), ["claude", "codex", "muse"])
        XCTAssertEqual(tools[0].update, ["/u/.local/bin/claude", "update"])
        XCTAssertEqual(tools[1].update, [bin.appendingPathComponent("npm").path, "install", "-g", "@openai/codex@latest"])
        XCTAssertEqual(tools[2].environment, ["MUSE_LAUNCHER_INSTALL": "1"])
        XCTAssertEqual(tools[1].latestVersion, [bin.appendingPathComponent("npm").path, "view", "@openai/codex@latest", "version"])
        XCTAssertNil(tools[0].latestVersion)
        XCTAssertNil(tools[2].latestVersion)

        let bundled = CLITool.installed { $0 == "codex" ? URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex") : nil }
        XCTAssertTrue(bundled.isEmpty)
    }

    func testResultSummaries() {
        XCTAssertEqual(CLIUpdateResult(name: "codex", before: "0.163.0", after: "0.164.0", succeeded: true, detail: "").summary, "codex 0.163.0 → 0.164.0")
        XCTAssertEqual(CLIUpdateResult(name: "grok", before: "1.0.62", after: "1.0.62", succeeded: true, detail: "").summary, "grok 1.0.62 up to date")
        XCTAssertEqual(CLIUpdateResult(name: "muse", before: nil, after: nil, succeeded: false, detail: "").summary, "muse: update failed")
    }

    private let codex = CLITool(
        name: "codex", executable: URL(fileURLWithPath: "/n/bin/codex"),
        update: ["/n/bin/npm", "install", "-g", "@openai/codex@latest"],
        latestVersion: ["/n/bin/npm", "view", "@openai/codex@latest", "version"]
    )

    /// Answers `--version` with each entry of `installed` in turn and records every command run.
    private func fakeRunner(installed: [String], latest: (Int32, String)) -> (CLIUpdater.CommandRunner, () -> [[String]]) {
        final class Calls: @unchecked Sendable { var commands: [[String]] = []; var versions: [String] = [] }
        let calls = Calls()
        calls.versions = installed
        let run: CLIUpdater.CommandRunner = { command, _, _ in
            calls.commands.append(command)
            if command.last == "--version" { return (0, "codex-cli \(calls.versions.count > 1 ? calls.versions.removeFirst() : calls.versions[0])\n") }
            if command.contains("view") { return latest }
            return (0, "changed 2 packages in 2s\n")
        }
        return (run, { calls.commands })
    }

    func testSkipsTheInstallWhenTheInstalledVersionIsTheLatest() {
        let (run, commands) = fakeRunner(installed: ["0.164.0"], latest: (0, "0.164.0\n"))

        let (result, log) = CLIUpdater.update(codex, run: run)

        XCTAssertFalse(commands().contains(codex.update), "a same-version npm install swaps files under running Codex processes")
        XCTAssertEqual(result, CLIUpdateResult(name: "codex", before: "0.164.0", after: "0.164.0", succeeded: true, detail: "Already up to date (0.164.0)"))
        XCTAssertEqual(result.summary, "codex 0.164.0 up to date")
        XCTAssertTrue(log.contains("0.164.0 is the latest, install skipped"), log)
    }

    func testInstallsWhenANewerVersionIsOut() {
        let (run, commands) = fakeRunner(installed: ["0.164.0", "0.165.0"], latest: (0, "0.165.0\n"))

        let (result, log) = CLIUpdater.update(codex, run: run)

        XCTAssertTrue(commands().contains(codex.update))
        XCTAssertEqual(result.summary, "codex 0.164.0 → 0.165.0")
        XCTAssertTrue(log.contains("-- codex: 0.164.0 -> 0.165.0 (exit 0)"), log)
    }

    func testInstallsAnywayWhenTheLatestVersionCantBeChecked() {
        let (run, commands) = fakeRunner(installed: ["0.164.0"], latest: (1, "npm error network\n"))

        let (result, _) = CLIUpdater.update(codex, run: run)

        XCTAssertTrue(commands().contains(codex.update))
        XCTAssertTrue(result.succeeded)
    }

    func testToolsWithoutAVersionCheckAlwaysRunTheirUpdate() {
        let claude = CLITool(name: "claude", executable: URL(fileURLWithPath: "/u/claude"), update: ["/u/claude", "update"])
        let (run, commands) = fakeRunner(installed: ["2.1.310"], latest: (0, "2.1.310"))

        _ = CLIUpdater.update(claude, run: run)

        XCTAssertEqual(commands(), [["/u/claude", "--version"], ["/u/claude", "update"], ["/u/claude", "--version"]])
    }

    /// Runs the real process path against stand-in `codex` and `npm` scripts, so nothing touches a real install.
    func testSkipsTheInstallWithRealProcesses() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let installed = bin.appendingPathComponent("installed")
        let scripts = [
            "codex": "#!/bin/sh\necho codex-cli 0.164.0\n",
            "npm": "#!/bin/sh\nif [ \"$1\" = view ]; then echo 0.164.0; else touch '\(installed.path)'; fi\n"
        ]
        for (name, body) in scripts {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(name).path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o755])
        }
        let tool = try XCTUnwrap(CLITool.installed { $0 == "codex" ? bin.appendingPathComponent("codex") : nil }.first)

        let (result, _) = CLIUpdater.update(tool)

        XCTAssertEqual(result.summary, "codex 0.164.0 up to date")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }
}
