import XCTest
@testable import TokenStatsApp

final class LimitsJSONTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    private func document(_ accounts: [LimitAccount]) throws -> [String: Any] {
        let data = try LimitsJSON.encode(accounts, generatedAt: now)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodesWindowKindsRemainingPercentAndDates() throws {
        var account = LimitAccount(id: "claude:main", provider: .claude, email: "mike@example.com", plan: "Max", source: "~/.claude")
        account.configDir = URL(fileURLWithPath: "/Users/test/.claude")
        account.windows = [
            LimitWindow(id: "session", title: "5-hour", usedPercent: 12.5, resetsAt: now, detail: "session detail"),
            LimitWindow(id: "weekly_all", title: "Weekly", usedPercent: 25, resetsAt: nil),
            LimitWindow(id: "weekly_scoped", title: "Weekly Fable", usedPercent: 5, resetsAt: nil),
            LimitWindow(id: "daily", title: "Daily", usedPercent: 0, resetsAt: nil),
            LimitWindow(id: "monthly", title: "Monthly", usedPercent: 100, resetsAt: nil),
            LimitWindow(id: "iguana_necktie", title: "$250 allowance", usedPercent: 110, resetsAt: nil),
            LimitWindow(id: "unknown", title: "Usage", usedPercent: -10, resetsAt: nil),
            LimitWindow(id: "codex.primary", title: "5-hour Spark", usedPercent: 20, resetsAt: nil)
        ]

        let result = try document([account])
        XCTAssertEqual(result["version"] as? Int, 1)
        XCTAssertEqual(result["generatedAt"] as? String, "1970-01-01T00:00:00Z")
        let encoded = try XCTUnwrap((result["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(encoded["provider"] as? String, "Claude")
        XCTAssertEqual(encoded["plan"] as? String, "Max")
        XCTAssertEqual(encoded["email"] as? String, "mike@example.com")
        XCTAssertEqual(encoded["configDir"] as? String, "/Users/test/.claude")
        XCTAssertEqual(encoded["label"] as? String, "~/.claude")
        let windows = try XCTUnwrap(encoded["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.compactMap { $0["kind"] as? String },
                       ["five_hour", "weekly", "weekly_model", "daily", "monthly", "allowance", "other", "five_hour"])
        XCTAssertEqual(windows.compactMap { $0["title"] as? String }, account.windows.map(\.title))
        XCTAssertEqual(windows.compactMap { $0["remainingPercent"] as? Double }, [87.5, 75, 95, 100, 0, 0, 100, 80])
        XCTAssertEqual(windows[0]["resetsAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(windows[0]["detail"] as? String, "session detail")
    }

    func testAbsentValuesAreExplicitNullAndUnknownFoldersStayUnknown() throws {
        var account = LimitAccount(id: "claude:unknown", provider: .claude, source: "")
        account.windows = [LimitWindow(id: "unknown", title: "Usage", usedPercent: 0, resetsAt: nil)]

        let result = try document([account])
        let encoded = try XCTUnwrap((result["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(encoded.keys), ["provider", "plan", "email", "configDir", "label", "windows", "notice", "usageReadAt"])
        for key in ["plan", "email", "configDir", "label", "notice"] {
            XCTAssertTrue(encoded[key] is NSNull, key)
        }
        let window = try XCTUnwrap((encoded["windows"] as? [[String: Any]])?.first)
        XCTAssertTrue(window["resetsAt"] is NSNull)
        XCTAssertTrue(window["detail"] is NSNull)
    }

    func testIncludesEveryProviderAndCombinesErrorAndNotesIntoNotice() throws {
        let accounts = LimitProvider.allCases.map {
            LimitAccount(id: $0.rawValue, provider: $0, source: $0.rawValue, notes: ["Some usage unavailable"], error: "Sign-in expired")
        }
        let encoded = try XCTUnwrap(try document(accounts)["accounts"] as? [[String: Any]])
        XCTAssertEqual(encoded.compactMap { $0["provider"] as? String }, LimitProvider.allCases.map(\.rawValue))
        XCTAssertEqual(encoded.first?["notice"] as? String, "Sign-in expired · Some usage unavailable")
    }

    func testEncodingIsDeterministicWithSortedKeysAndEmptyAccounts() throws {
        let data = try LimitsJSON.encode([], generatedAt: now)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"accounts":[],"complete":true,"generatedAt":"1970-01-01T00:00:00Z","version":1}"#)
        XCTAssertEqual(data, try LimitsJSON.encode([], generatedAt: now))
    }

    func testAddedAccountFolderAndExplicitConfigOverrideAreAbsolute() throws {
        let added = LimitAccount(id: "claude:added", provider: .claude, source: "claude-2",
                                 folder: URL(fileURLWithPath: "/Users/test/Accounts/claude-2"))
        var overridden = LimitAccount(id: "codex:custom", provider: .codex, source: "~/.codex")
        overridden.configDir = URL(fileURLWithPath: "/Users/test/custom-codex")

        let encoded = try XCTUnwrap(try document([added, overridden])["accounts"] as? [[String: Any]])
        XCTAssertEqual(encoded[0]["configDir"] as? String, "/Users/test/Accounts/claude-2")
        XCTAssertEqual(encoded[1]["configDir"] as? String, "/Users/test/custom-codex")
        XCTAssertEqual(encoded[1]["label"] as? String, "~/.codex")
    }

    func testDatesAreNormalizedToUTC() throws {
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T12:34:56+08:00"))
        var account = LimitAccount(id: "muse:main", provider: .muse, source: "~/.config/muse")
        account.windows = [LimitWindow(id: "weekly", title: "Weekly", usedPercent: 10, resetsAt: reset)]

        let data = try LimitsJSON.encode([account], generatedAt: reset)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["generatedAt"] as? String, "2026-10-19T04:34:56Z")
        let encoded = try XCTUnwrap((result["accounts"] as? [[String: Any]])?.first)
        let window = try XCTUnwrap((encoded["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(window["resetsAt"] as? String, "2026-10-19T04:34:56Z")
    }

    func testSnapshotCreatesDirectoryAndReplacesDocumentEvenWhenEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Token Stats/limits.json")
        let account = LimitAccount(id: "codex:main", provider: .codex, source: "~/.codex")

        try LimitsJSON.writeSnapshot([], generatedAt: now, to: url)
        XCTAssertEqual(try Data(contentsOf: url), try LimitsJSON.encode([], generatedAt: now))
        try LimitsJSON.writeSnapshot([account], generatedAt: now, to: url)
        XCTAssertEqual(try Data(contentsOf: url), try LimitsJSON.encode([account], generatedAt: now))
        let later = now.addingTimeInterval(3600)
        try LimitsJSON.writeSnapshot([account], generatedAt: later, to: url)
        let latest = try Data(contentsOf: url)
        XCTAssertEqual(latest, try LimitsJSON.encode([account], generatedAt: later))
        // Removing the last login must not leave the old accounts behind.
        try LimitsJSON.writeSnapshot([], generatedAt: later, to: url)
        XCTAssertNotEqual(try Data(contentsOf: url), latest)
        XCTAssertEqual(try Data(contentsOf: url), try LimitsJSON.encode([], generatedAt: later))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["limits.json"])
    }

    func testUsageReadAtSaysHowOldTheNumbersAre() throws {
        let readAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T12:12:00Z"))
        let checkedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T12:40:00Z"))
        var cached = LimitAccount(id: "claude:main", provider: .claude, source: "~/.claude", fetchedAt: checkedAt)
        cached.windows = [LimitWindow(id: "seven_day", title: "Weekly", usedPercent: 20, resetsAt: nil)]
        cached.usageReadAt = readAt
        cached.notes = ["Couldn't check usage just now, so these are from 8:12 pm."]
        // Other providers read their numbers on every check.
        var codex = LimitAccount(id: "codex:main", provider: .codex, source: "~/.codex", fetchedAt: checkedAt)
        codex.windows = [LimitWindow(id: "codex.primary", title: "Weekly", usedPercent: 6, resetsAt: nil)]
        var paused = LimitAccount(id: "claude:other", provider: .claude, source: "claude-1", fetchedAt: checkedAt)
        paused.notes = ["Anthropic paused usage checks until 8:57 pm. The account still works."]

        let encoded = try XCTUnwrap(try document([cached, codex, paused])["accounts"] as? [[String: Any]])

        XCTAssertEqual(encoded[0]["usageReadAt"] as? String, "2026-10-24T12:12:00Z")
        XCTAssertEqual(encoded[0]["notice"] as? String, "Couldn't check usage just now, so these are from 8:12 pm.")
        XCTAssertEqual(encoded[1]["usageReadAt"] as? String, "2026-10-24T12:40:00Z")
        XCTAssertTrue(encoded[2]["usageReadAt"] is NSNull)
        XCTAssertEqual(encoded[2]["notice"] as? String, "Anthropic paused usage checks until 8:57 pm. The account still works.")
    }

    func testIncompleteRefreshIsMarkedInTheDocument() throws {
        let complete = try JSONSerialization.jsonObject(with: LimitsJSON.encode([], generatedAt: now)) as? [String: Any]
        let partial = try JSONSerialization.jsonObject(with: LimitsJSON.encode([], generatedAt: now, complete: false)) as? [String: Any]
        XCTAssertEqual(complete?["complete"] as? Bool, true)
        XCTAssertEqual(partial?["complete"] as? Bool, false)
    }
}
