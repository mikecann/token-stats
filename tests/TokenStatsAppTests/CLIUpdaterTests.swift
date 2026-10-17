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

        let bundled = CLITool.installed { $0 == "codex" ? URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex") : nil }
        XCTAssertTrue(bundled.isEmpty)
    }

    func testResultSummaries() {
        XCTAssertEqual(CLIUpdateResult(name: "codex", before: "0.163.0", after: "0.164.0", succeeded: true, detail: "").summary, "codex 0.163.0 → 0.164.0")
        XCTAssertEqual(CLIUpdateResult(name: "grok", before: "1.0.62", after: "1.0.62", succeeded: true, detail: "").summary, "grok 1.0.62 up to date")
        XCTAssertEqual(CLIUpdateResult(name: "muse", before: nil, after: nil, succeeded: false, detail: "").summary, "muse: update failed")
    }
}
