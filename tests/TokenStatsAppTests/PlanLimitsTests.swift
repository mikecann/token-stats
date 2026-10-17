import XCTest
@testable import TokenStatsApp

final class PlanLimitsTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testCodexParserReadsAccountWeeklyWindowCreditsAndResets() throws {
        let account = try json(#"{"account":{"type":"chatgpt","email":"mike@example.com","planType":"pro"},"requiresOpenaiAuth":true}"#)
        let limits = try json(#"""
        {"ordinaryUsageAllowed":true,
         "rateLimits":{"limitId":"codex","primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1792650106},"secondary":null},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1792650106},"secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1792600000},"credits":{"hasCredits":true,"unlimited":false,"balance":"64390.41"},"planType":"pro"}},
         "rateLimitResetCredits":{"availableCount":2,"credits":null}}
        """#)
        var target = LimitAccount(id: "codex:~/.codex", provider: .codex, source: "~/.codex")

        CodexLimitsParser.apply(account: account, rateLimits: limits, to: &target)

        XCTAssertEqual(target.email, "mike@example.com")
        XCTAssertEqual(target.plan, "Pro")
        XCTAssertEqual(target.windows.map(\.title), ["Weekly", "5-hour"])
        XCTAssertEqual(target.windows[0].usedPercent, 6)
        XCTAssertEqual(target.windows[0].remainingPercent, 94)
        XCTAssertEqual(target.windows[0].resetsAt, Date(timeIntervalSince1970: 1792650106))
        XCTAssertEqual(target.tightestWindow?.title, "5-hour")
        XCTAssertEqual(target.notes, ["64,390 credits", "2 limit resets available"])
    }

    func testCodexParserFallsBackToSingleSnapshotAndNamesExtraLimits() throws {
        let limits = try json(#"""
        {"rateLimitsByLimitId":{
          "codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300}},
          "codex_spark":{"limitId":"codex_spark","limitName":"Spark","primary":{"usedPercent":80,"windowDurationMins":10080}}}}
        """#)
        var target = LimitAccount(id: "x", provider: .codex, source: "x")

        CodexLimitsParser.apply(account: nil, rateLimits: limits, to: &target)

        XCTAssertEqual(target.windows.map(\.title), ["5-hour", "Weekly Spark"])
        XCTAssertNil(target.windows[0].resetsAt)
    }

    func testCodexParserFlagsSignedOutAccount() throws {
        var target = LimitAccount(id: "x", provider: .codex, source: "x")
        CodexLimitsParser.apply(account: try json(#"{"account":null,"requiresOpenaiAuth":true}"#), rateLimits: nil, to: &target)
        XCTAssertEqual(target.error, "Not signed in")
    }

    func testClaudeParserOrdersWindowsAndSkipsNullOnes() throws {
        let usage = try json(#"""
        {"seven_day":{"utilization":35.0,"resets_at":"2026-10-20T03:00:00.123456+00:00"},
         "five_hour":{"utilization":12,"resets_at":"2026-10-17T05:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":3,"resets_at":null},
         "extra_usage":{"is_enabled":false,"utilization":null}}
        """#)

        let windows = ClaudeLimitsParser.windows(from: usage)

        XCTAssertEqual(windows.map(\.title), ["5-hour", "Weekly", "Weekly Sonnet"])
        XCTAssertEqual(windows[1].usedPercent, 35)
        XCTAssertEqual(windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-20T03:00:00Z"))
        XCTAssertNil(windows[2].resetsAt)
    }

    func testClaudeProfileSetsEmailAndPlan() throws {
        var target = LimitAccount(id: "c", provider: .claude, source: "Claude Code")
        ClaudeLimitsParser.apply(
            profile: try json(#"{"account":{"email_address":"mike@example.com"},"organization":{"organization_type":"claude_max"}}"#),
            to: &target
        )
        XCTAssertEqual(target.email, "mike@example.com")
        XCTAssertEqual(target.plan, "Max")
    }

    func testWindowTitlesAndResetText() {
        XCTAssertEqual(LimitFormat.windowTitle(minutes: 300), "5-hour")
        XCTAssertEqual(LimitFormat.windowTitle(minutes: 10080), "Weekly")
        XCTAssertEqual(LimitFormat.windowTitle(minutes: nil), "Usage")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(LimitFormat.resetText(Date(timeIntervalSince1970: 90 * 60), now: now), "resets in 1h 30m")
        XCTAssertEqual(LimitFormat.resetText(Date(timeIntervalSince1970: 20), now: now), "resets in 1m")
    }

    func testClaudeParserReadsLimitsListDollarAllowanceAndExtraSpend() throws {
        let usage = try json(#"""
        {"five_hour":{"utilization":10,"resets_at":"2026-10-17T04:29:59Z"},
         "seven_day":{"utilization":18,"resets_at":"2026-10-22T16:59:59Z"},
         "iguana_necktie":{"limit_dollars":250,"remaining_dollars":132.7903,"used_dollars":117.2097,"utilization":46.88,"resets_at":"2026-11-05T07:59:00+00:00"},
         "amber_gauge":null,
         "limits":[
          {"kind":"session","percent":10,"resets_at":"2026-10-17T04:29:59Z","scope":null},
          {"kind":"weekly_all","percent":18,"resets_at":"2026-10-22T16:59:59Z","scope":null},
          {"kind":"weekly_scoped","percent":0,"resets_at":"2026-10-22T17:00:00Z","scope":{"model":{"display_name":"Fable","id":null},"surface":null}}],
         "spend":{"enabled":true,"used":{"amount_minor":4885,"currency":"USD","exponent":2}}}
        """#)

        let windows = ClaudeLimitsParser.windows(from: usage)

        XCTAssertEqual(windows.map(\.title), ["5-hour", "Weekly", "Weekly Fable", "$250 allowance"])
        XCTAssertEqual(windows[3].detail, "$132.79 left")
        XCTAssertEqual(windows[3].usedPercent, 46.88)
        XCTAssertEqual(ClaudeLimitsParser.notes(from: usage), ["$48.85 extra usage spent"])
    }

    func testMergerKeepsOneCardPerEmailAndPrefersYourOwnLogin() {
        let folder = URL(fileURLWithPath: "/tmp/Accounts/claude-2")
        let main = LimitAccount(id: "claude:main", provider: .claude, email: "mike@example.com", source: "~/.claude")
        let added = LimitAccount(id: "claude:2", provider: .claude, email: "Mike@example.com", source: "claude-2", folder: folder)
        let other = LimitAccount(id: "claude:1", provider: .claude, email: "work@example.com", source: "claude-1", folder: folder)
        let codex = LimitAccount(id: "codex:main", provider: .codex, email: "mike@example.com", source: "~/.codex")

        let merged = LimitAccountMerger.merge([added, other, main, codex])

        XCTAssertEqual(Set(merged.kept.map(\.id)), ["claude:main", "claude:1", "codex:main"])
        XCTAssertEqual(merged.duplicates.map(\.id), ["claude:2"])
    }

    func testMergerSwapsInTheWorkingLoginWhenTheFirstOneErrored() {
        var broken = LimitAccount(id: "a", provider: .claude, email: "mike@example.com", source: "~/.claude")
        broken.error = "Sign-in expired"
        let working = LimitAccount(id: "b", provider: .claude, email: "mike@example.com", source: "claude-1", folder: URL(fileURLWithPath: "/x/claude-1"))

        let merged = LimitAccountMerger.merge([broken, working])

        XCTAssertEqual(merged.kept.map(\.id), ["b"])
        XCTAssertEqual(merged.duplicates.map(\.id), ["a"])
    }
}
