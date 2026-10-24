import XCTest
@testable import TokenStatsApp

final class ClaudeUsageCacheTests: XCTestCase {
    private let perth = TimeZone(identifier: "Australia/Perth")!
    private let australia = Locale(identifier: "en_AU")
    private let now = ISO8601DateFormatter().date(from: "2026-10-24T12:40:00Z")!      // 8:40 pm in Perth
    private let readAt = ISO8601DateFormatter().date(from: "2026-10-24T12:12:00Z")!   // 8:12 pm
    private let pauseEnd = ISO8601DateFormatter().date(from: "2026-10-24T12:57:00Z")! // 8:57 pm

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private var windows: [LimitWindow] {
        [
            LimitWindow(id: "five_hour", title: "5-hour", usedPercent: 40, resetsAt: date("2026-10-24T14:00:00Z")),
            LimitWindow(id: "seven_day", title: "Weekly", usedPercent: 20, resetsAt: date("2026-10-29T03:00:00Z"))
        ]
    }

    private var reading: ClaudeUsageCacheEntry {
        ClaudeUsageCacheEntry(windows: windows, notes: ["$48.85 extra usage spent"], readAt: readAt, checkedAt: readAt,
                              email: "mike@example.com")
    }

    private var profile: [String: Any] {
        ["account": ["email_address": "mike@example.com"], "organization": ["organization_type": "claude_max"]]
    }

    /// The system puts a narrow space before am/pm; plain spaces are easier to read in assertions.
    private func plain(_ notes: [String]) -> [String] {
        notes.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    private func show(_ outcome: ClaudeUsageOutcome, cached: ClaudeUsageCacheEntry?, profile: [String: Any]? = nil,
                      at time: Date? = nil) -> LimitAccount {
        var account = LimitAccount(id: "claude:main", provider: .claude, plan: "Pro", source: "~/.claude")
        ClaudeLimitsParser.apply(outcome, cached: cached, profile: profile, now: time ?? now, timeZone: perth,
                                 locale: australia, to: &account)
        return account
    }

    private func temporaryCache() -> (ClaudeUsageCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Token Stats/claude-usage-cache.json")
        return (ClaudeUsageCache(url: url), url)
    }

    // MARK: Whether to ask

    func testAsksWhenNothingIsCached() {
        XCTAssertEqual(ClaudeUsagePolicy.check(nil, now: now), .ask)
        XCTAssertEqual(ClaudeUsagePolicy.check(ClaudeUsageCacheEntry(), now: now), .ask)
    }

    func testWaitsTenMinutesAfterTheLastCheck() {
        var entry = reading
        entry.checkedAt = now.addingTimeInterval(-(10 * 60 - 1))
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now), .recent)
        entry.checkedAt = now.addingTimeInterval(-10 * 60)
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now), .ask)
    }

    func testAPauseHoldsEveryCallerUntilItEnds() {
        var entry = reading
        entry.checkedAt = now.addingTimeInterval(-3600)
        entry.pausedUntil = pauseEnd
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now), .paused(until: pauseEnd))
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: pauseEnd), .ask)
        // A pause shorter than the gap still waits out the rest of the 10 minutes.
        entry.checkedAt = now
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now.addingTimeInterval(120)), .paused(until: pauseEnd))
        entry.pausedUntil = now.addingTimeInterval(60)
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now.addingTimeInterval(120)), .recent)
    }

    func testWaitsInsideTheGapEvenWithNoReadingToShow() {
        // Another process may be asking right now, or the last check failed. Asking again would be
        // the very thing that gets a login a 429, so the gap holds whether or not there's a reading.
        let neverRead = ClaudeUsageCacheEntry(checkedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(ClaudeUsagePolicy.check(neverRead, now: now), .recent)

        var allReset = reading
        allReset.checkedAt = now.addingTimeInterval(-60)
        allReset.windows = [LimitWindow(id: "five_hour", title: "5-hour", usedPercent: 90, resetsAt: now.addingTimeInterval(-1))]
        XCTAssertEqual(ClaudeUsagePolicy.check(allReset, now: now), .recent)

        // A plan that reports no limits at all is still a reading, so it waits like any other.
        var noLimits = reading
        noLimits.windows = []
        noLimits.checkedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(ClaudeUsagePolicy.check(noLimits, now: now), .recent)
    }

    func testACheckTimeInTheFutureDoesNotBlockAsking() {
        var entry = reading
        entry.checkedAt = now.addingTimeInterval(3600)
        XCTAssertEqual(ClaudeUsagePolicy.check(entry, now: now), .ask)
    }

    // MARK: Retry-After

    func testRetryAfterSecondsSetThePause() {
        XCTAssertEqual(ClaudeUsagePolicy.pauseEnd(retryAfter: "1560", now: now), now.addingTimeInterval(1560))
        XCTAssertEqual(ClaudeUsagePolicy.pauseEnd(retryAfter: " 30 ", now: now), now.addingTimeInterval(30))
        XCTAssertEqual(ClaudeUsagePolicy.pauseEnd(retryAfter: "0", now: now), now)
    }

    func testMissingOrUnreadableRetryAfterPausesFifteenMinutes() {
        for value in [nil, "", "soon", "-5", "12.5", "Wed, 21 Oct 2026 07:28:00 GMT"] {
            XCTAssertEqual(ClaudeUsagePolicy.pauseEnd(retryAfter: value, now: now), now.addingTimeInterval(15 * 60), value ?? "nil")
        }
    }

    func testAHugeRetryAfterIsCappedAtADay() {
        XCTAssertEqual(ClaudeUsagePolicy.pauseEnd(retryAfter: "999999999", now: now), now.addingTimeInterval(24 * 3600))
    }

    // MARK: Recording what happened

    func testClaimMarksTheCheckSoOtherCallersWait() {
        let claimed = ClaudeUsagePolicy.claim(reading, now: now)
        XCTAssertEqual(claimed.checkedAt, now)
        XCTAssertEqual(claimed.windows, reading.windows)
        XCTAssertEqual(claimed.readAt, readAt)
        XCTAssertEqual(ClaudeUsagePolicy.check(claimed, now: now.addingTimeInterval(1)), .recent)
        XCTAssertEqual(ClaudeUsagePolicy.claim(nil, now: now), ClaudeUsageCacheEntry(checkedAt: now))
        // A claim on a login with no reading yet holds other callers too.
        XCTAssertEqual(ClaudeUsagePolicy.check(ClaudeUsagePolicy.claim(nil, now: now), now: now.addingTimeInterval(1)), .recent)
    }

    func testAGoodReadingReplacesTheCacheAndEndsAnyPause() {
        var entry = reading
        entry.pausedUntil = now.addingTimeInterval(-5)
        let fresh = [LimitWindow(id: "five_hour", title: "5-hour", usedPercent: 50, resetsAt: nil)]

        let recorded = ClaudeUsagePolicy.record(.read(windows: fresh, notes: []), in: entry, email: "mike@example.com", now: now)

        XCTAssertEqual(recorded, ClaudeUsageCacheEntry(windows: fresh, notes: [], readAt: now, checkedAt: now, email: "mike@example.com"))
    }

    func testARateLimitKeepsTheReadingAndPauses() {
        let recorded = ClaudeUsagePolicy.record(.rateLimited(retryAfter: "1020"), in: reading, email: "mike@example.com", now: now)
        XCTAssertEqual(recorded?.windows, reading.windows)
        XCTAssertEqual(recorded?.notes, reading.notes)
        XCTAssertEqual(recorded?.readAt, readAt)
        XCTAssertEqual(recorded?.checkedAt, now)
        XCTAssertEqual(recorded?.pausedUntil, pauseEnd)

        let first = ClaudeUsagePolicy.record(.rateLimited(retryAfter: nil), in: nil, email: nil, now: now)
        XCTAssertEqual(first, ClaudeUsageCacheEntry(checkedAt: now, pausedUntil: now.addingTimeInterval(15 * 60)))
    }

    func testAFailedCheckKeepsTheReadingAndCountsAsACheck() {
        let recorded = ClaudeUsagePolicy.record(.unavailable("The request timed out."), in: reading, email: nil, now: now)
        var expected = reading
        expected.checkedAt = now
        XCTAssertEqual(recorded, expected)
    }

    func testALoginProblemLetsTheNextRefreshAskAgain() {
        let claimed = ClaudeUsagePolicy.claim(reading, now: now)
        let recorded = ClaudeUsagePolicy.record(.failed("Anthropic returned 401: sign in again"), in: claimed, email: nil, now: now)
        XCTAssertNil(recorded?.checkedAt)
        XCTAssertEqual(recorded?.windows, reading.windows)
        XCTAssertEqual(ClaudeUsagePolicy.check(recorded, now: now.addingTimeInterval(60)), .ask)
    }

    func testSkippingChangesNothing() {
        XCTAssertEqual(ClaudeUsagePolicy.record(.recent, in: reading, email: "mike@example.com", now: now), reading)
        XCTAssertEqual(ClaudeUsagePolicy.record(.paused(until: pauseEnd), in: reading, email: nil, now: now), reading)
        XCTAssertNil(ClaudeUsagePolicy.record(.recent, in: nil, email: nil, now: now))
    }

    func testAReadingFromAnotherAccountIsNotKept() {
        XCTAssertTrue(ClaudeUsagePolicy.sameAccount(reading, email: "Mike@Example.com"))
        XCTAssertTrue(ClaudeUsagePolicy.sameAccount(reading, email: nil))
        XCTAssertFalse(ClaudeUsagePolicy.sameAccount(reading, email: "work@example.com"))

        let recorded = ClaudeUsagePolicy.record(.rateLimited(retryAfter: "60"), in: reading, email: "work@example.com", now: now)
        XCTAssertEqual(recorded, ClaudeUsageCacheEntry(checkedAt: now, pausedUntil: now.addingTimeInterval(60), email: "work@example.com"))
    }

    // MARK: What the card shows

    func testAGoodReadingShowsFreshWindows() {
        let account = show(.read(windows: windows, notes: ["$48.85 extra usage spent"]), cached: reading, profile: profile)
        XCTAssertNil(account.error)
        XCTAssertEqual(account.windows, windows)
        XCTAssertEqual(account.notes, ["$48.85 extra usage spent"])
        XCTAssertEqual(account.usageReadAt, now)
        XCTAssertEqual(account.email, "mike@example.com")
        XCTAssertEqual(account.plan, "Max")
    }

    func testARateLimitShowsTheLastReadingAndAPauseNote() {
        let cached = ClaudeUsagePolicy.record(.rateLimited(retryAfter: "1020"), in: reading, email: nil, now: now)
        let account = show(.rateLimited(retryAfter: "1020"), cached: cached, profile: profile)
        XCTAssertNil(account.error)
        XCTAssertEqual(account.windows, windows)
        XCTAssertEqual(plain(account.notes), [
            "Anthropic paused usage checks until 8:57 pm, so these are from 8:12 pm. The account still works.",
            "$48.85 extra usage spent"
        ])
        XCTAssertEqual(account.usageReadAt, readAt)
        XCTAssertEqual(account.email, "mike@example.com")
    }

    func testARateLimitWithNothingCachedIsANoteNotAnError() {
        let cached = ClaudeUsagePolicy.record(.rateLimited(retryAfter: "1020"), in: nil, email: nil, now: now)
        let account = show(.rateLimited(retryAfter: "1020"), cached: cached, profile: profile)
        XCTAssertNil(account.error)
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertEqual(plain(account.notes), ["Anthropic paused usage checks until 8:57 pm. The account still works."])
        XCTAssertNil(account.usageReadAt)
        // The profile still names the account, so delegate can tell whose login it is.
        XCTAssertEqual(account.email, "mike@example.com")
        XCTAssertEqual(account.plan, "Max")
    }

    func testOtherFailuresShowTheLastReadingWithANote() {
        for failure in ["The request timed out.", "Anthropic returned HTTP 503: Overloaded"] {
            let account = show(.unavailable(failure), cached: reading)
            XCTAssertNil(account.error)
            XCTAssertEqual(account.windows, windows)
            XCTAssertEqual(plain(account.notes), ["Couldn't check usage just now, so these are from 8:12 pm.", "$48.85 extra usage spent"])
            XCTAssertEqual(account.usageReadAt, readAt)
        }
    }

    func testOtherFailuresWithNothingCachedStillShowTheError() {
        let account = show(.unavailable("The request timed out."), cached: nil, profile: profile)
        XCTAssertEqual(account.error, "The request timed out.")
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertTrue(account.notes.isEmpty)
        XCTAssertEqual(account.email, "mike@example.com")
    }

    func testLoginProblemsStayErrorsEvenWithACachedReading() {
        let account = show(.failed("Anthropic returned 401: sign in again"), cached: reading, profile: nil)
        XCTAssertEqual(account.error, "Anthropic returned 401: sign in again")
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertTrue(account.notes.isEmpty)
        XCTAssertNil(account.usageReadAt)
    }

    func testAPausedSkipShowsTheLastReading() {
        var cached = reading
        cached.pausedUntil = pauseEnd
        let account = show(.paused(until: pauseEnd), cached: cached)
        XCTAssertNil(account.error)
        XCTAssertEqual(account.windows, windows)
        XCTAssertEqual(plain(account.notes).first,
                       "Anthropic paused usage checks until 8:57 pm, so these are from 8:12 pm. The account still works.")
    }

    func testAPausedSkipWithNothingCachedShowsOnlyTheNote() {
        let account = show(.paused(until: pauseEnd), cached: ClaudeUsageCacheEntry(checkedAt: readAt, pausedUntil: pauseEnd))
        XCTAssertNil(account.error)
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertEqual(plain(account.notes), ["Anthropic paused usage checks until 8:57 pm. The account still works."])
    }

    func testARecentReadingShowsWithoutANote() {
        let account = show(.recent, cached: reading, at: readAt.addingTimeInterval(5 * 60))
        XCTAssertNil(account.error)
        XCTAssertEqual(account.windows, windows)
        XCTAssertEqual(account.notes, ["$48.85 extra usage spent"])
        XCTAssertEqual(account.usageReadAt, readAt)
    }

    func testARecentSkipWithNoReadingSaysSoCalmly() {
        let account = show(.recent, cached: ClaudeUsageCacheEntry(checkedAt: now.addingTimeInterval(-60)))
        XCTAssertNil(account.error)
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertEqual(account.notes, ["No usage numbers yet. Token Stats checks again in a few minutes."])
        XCTAssertNil(account.usageReadAt)
    }

    func testARecentSkipAfterAFailedCheckStillSaysTheNumbersAreOld() {
        // Read at 8:12, the 8:35 check timed out, and it's 8:40 now.
        var cached = reading
        cached.checkedAt = now.addingTimeInterval(-5 * 60)
        let account = show(.recent, cached: cached)
        XCTAssertEqual(plain(account.notes), ["Couldn't check usage just now, so these are from 8:12 pm.", "$48.85 extra usage spent"])
    }

    func testAReadingFromAnotherDayNamesTheDay() {
        var cached = reading
        cached.readAt = date("2026-10-23T12:12:00Z")
        cached.windows = [windows[1]]
        let account = show(.unavailable("offline"), cached: cached)
        XCTAssertEqual(plain(account.notes).first, "Couldn't check usage just now, so these are from Fri 8:12 pm.")

        cached.readAt = date("2026-10-10T12:12:00Z")
        XCTAssertEqual(plain(show(.unavailable("offline"), cached: cached).notes).first,
                       "Couldn't check usage just now, so these are from 10 Oct at 8:12 pm.")
    }

    func testAPauseEndingTomorrowNamesTheDay() {
        let lateNight = date("2026-10-24T15:50:00Z") // 11:50 pm in Perth
        let account = show(.paused(until: lateNight.addingTimeInterval(1800)), cached: nil, at: lateNight)
        XCTAssertEqual(plain(account.notes), ["Anthropic paused usage checks until Sun 12:20 am. The account still works."])
    }

    func testWindowsThatHaveResetAreDropped() {
        let later = date("2026-10-24T14:30:00Z") // the 5-hour window reset at 14:00
        XCTAssertEqual(ClaudeUsagePolicy.current(windows, now: later).map(\.id), ["seven_day"])
        XCTAssertEqual(ClaudeUsagePolicy.current([LimitWindow(id: "x", title: "Usage", usedPercent: 1, resetsAt: nil)], now: later).count, 1)

        let account = show(.unavailable("offline"), cached: reading, at: later)
        XCTAssertEqual(account.windows.map(\.id), ["seven_day"])

        // Once every limit has reset, the old reading has nothing true left to show.
        let gone = show(.unavailable("offline"), cached: reading, at: date("2026-10-30T00:00:00Z"))
        XCTAssertEqual(gone.error, "offline")
        XCTAssertTrue(gone.windows.isEmpty)
        XCTAssertTrue(gone.notes.isEmpty)
    }

    // MARK: Sorting usage responses

    func testUsageResponsesAreSortedIntoOutcomes() {
        let usage = Data(#"{"five_hour":{"utilization":12,"resets_at":"2026-10-24T14:00:00Z"},"spend":{"enabled":true,"used":{"amount_minor":4885,"exponent":2}}}"#.utf8)
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 200, retryAfter: nil, body: usage), .read(
            windows: [LimitWindow(id: "five_hour", title: "5-hour", usedPercent: 12, resetsAt: date("2026-10-24T14:00:00Z"))],
            notes: ["$48.85 extra usage spent"]
        ))
        let limited = Data(#"{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}"#.utf8)
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 429, retryAfter: "1560", body: limited), .rateLimited(retryAfter: "1560"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 503, retryAfter: nil, body: Data(#"{"error":{"message":"Overloaded"}}"#.utf8)),
                       .unavailable("Anthropic returned HTTP 503: Overloaded"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 500, retryAfter: nil, body: Data("<html>".utf8)),
                       .unavailable("Anthropic returned HTTP 500"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 401, retryAfter: nil, body: Data()),
                       .failed("Anthropic returned 401: sign in again"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 403, retryAfter: nil, body: Data(#"{"error":{"message":"Forbidden"}}"#.utf8)),
                       .failed("Anthropic returned HTTP 403: Forbidden"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(status: 200, retryAfter: nil, body: Data("not json".utf8)),
                       .failed("Unexpected response from Anthropic"))
        XCTAssertEqual(ClaudeLimitsParser.outcome(error: URLError(.timedOut)), .unavailable(URLError(.timedOut).localizedDescription))
    }

    // MARK: The cache file

    func testCacheRoundTripsAnEntry() {
        let (cache, url) = temporaryCache()
        XCTAssertNil(cache.entry(for: "Claude Code-credentials"))
        var entry = reading
        entry.pausedUntil = pauseEnd

        let stored = cache.update("Claude Code-credentials") { _ in entry }

        XCTAssertEqual(stored, entry)
        XCTAssertEqual(cache.entry(for: "Claude Code-credentials"), entry)
        XCTAssertEqual(ClaudeUsageCache(url: url).entry(for: "Claude Code-credentials"), entry)
    }

    func testUpdatingOneLoginKeepsTheOthers() throws {
        let (cache, url) = temporaryCache()
        cache.update("a") { _ in self.reading }
        cache.update("b") { _ in ClaudeUsageCacheEntry(checkedAt: self.now) }
        // A field a newer Token Stats might add has to survive an older one rewriting another login.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var accounts = try XCTUnwrap(document["accounts"] as? [String: Any])
        accounts["c"] = ["checkedAt": "2026-10-24T12:00:00Z", "somethingNew": 7]
        document["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let updated = cache.update("a") { ClaudeUsagePolicy.claim($0, now: self.now) }

        XCTAssertEqual(updated?.checkedAt, now)
        XCTAssertEqual(cache.entry(for: "a")?.windows, reading.windows)
        XCTAssertEqual(cache.entry(for: "b"), ClaudeUsageCacheEntry(checkedAt: now))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 1)
        XCTAssertEqual(((saved["accounts"] as? [String: Any])?["c"] as? [String: Any])?["somethingNew"] as? Int, 7)
        XCTAssertEqual(cache.entry(for: "c")?.checkedAt, date("2026-10-24T12:00:00Z"))
    }

    func testAMissingOrBrokenCacheReadsAsEmptyAndIsReplaced() throws {
        let (cache, url) = temporaryCache()
        XCTAssertNil(cache.update("a") { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(cache.entry(for: "a"))

        cache.update("a") { _ in self.reading }
        XCTAssertEqual(cache.entry(for: "a"), reading)
    }

    func testConcurrentUpdatesKeepEveryLogin() {
        let (cache, _) = temporaryCache()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            // A separate value per call, like separate processes, each with its own file handle.
            ClaudeUsageCache(url: cache.url).update("login-\(index)") { _ in ClaudeUsageCacheEntry(checkedAt: self.now) }
            cache.update("shared") { ClaudeUsagePolicy.claim($0, now: self.now) }
        }
        for index in 0..<24 {
            XCTAssertEqual(cache.entry(for: "login-\(index)")?.checkedAt, now, "login-\(index)")
        }
        XCTAssertEqual(cache.entry(for: "shared")?.checkedAt, now)
    }
}
