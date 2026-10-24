import Foundation

/// The last good usage reading for one Claude login. It lives in `claude-usage-cache.json` so the
/// app and every `token-stats limits` run share it, and a restart doesn't mean asking again.
struct ClaudeUsageCacheEntry: Codable, Equatable, Sendable {
    var windows: [LimitWindow] = []
    var notes: [String] = []
    /// When `windows` and `notes` came back from Anthropic. Nil before the first good reading.
    var readAt: Date?
    /// When usage was last asked for, whatever the answer. It's set just before asking, so another
    /// process that turns up mid-request waits instead of asking too.
    var checkedAt: Date?
    /// Anthropic answered 429 and said to wait until then.
    var pausedUntil: Date?
    /// Whose reading it is, from the profile, so a different account signed in to the same folder
    /// never shows someone else's numbers.
    var email: String?
}

extension ClaudeUsageCacheEntry {
    /// Missing fields are fine, so an entry written by another version of Token Stats still reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeIfPresent([LimitWindow].self, forKey: .windows) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

/// Whether a refresh should ask Anthropic for a login's usage.
enum ClaudeUsageCheck: Equatable, Sendable {
    case ask
    /// Asked within the last 10 minutes, so the cached reading stands.
    case recent
    /// Anthropic said to wait.
    case paused(until: Date)
}

/// What came of a refresh's usage check, asked or not.
enum ClaudeUsageOutcome: Equatable, Sendable {
    case read(windows: [LimitWindow], notes: [String])
    /// HTTP 429, with the Retry-After header as sent.
    case rateLimited(retryAfter: String?)
    /// No connection, a timeout or a 5xx. The last reading is still worth showing.
    case unavailable(String)
    /// The login was turned down (401, 403) or the answer made no sense. Shown as an error.
    case failed(String)
    /// Not asked: Anthropic said to wait.
    case paused(until: Date)
    /// Not asked: another refresh asked within the last 10 minutes.
    case recent
}

/// Anthropic's usage endpoint turns a login away with a 429 for half an hour or so when it's asked
/// too often, and a card that loses its numbers then reads as if the plan ran out. So each login
/// asks at most every 10 minutes, waits out any Retry-After, and shows its last good reading in
/// between. These are the decisions, kept pure so they can be tested.
enum ClaudeUsagePolicy {
    /// However many refreshes, menu opens and `token-stats limits` runs there are.
    static let gap: TimeInterval = 10 * 60
    /// The wait after a 429 without a Retry-After in seconds.
    static let defaultPause: TimeInterval = 15 * 60
    /// The longest wait taken from a Retry-After, so a nonsense value can't stop checks for good.
    static let longestPause: TimeInterval = 24 * 60 * 60

    static func check(_ entry: ClaudeUsageCacheEntry?, now: Date) -> ClaudeUsageCheck {
        guard let entry else { return .ask }
        if let pausedUntil = entry.pausedUntil, pausedUntil > now, pausedUntil.timeIntervalSince(now) <= longestPause {
            return .paused(until: pausedUntil)
        }
        // A check time in the future means the clock moved back, so it doesn't count. The gap holds
        // even with no reading to show: another process may be asking right now, and asking again
        // the moment a check fails is what gets a login a 429.
        if let checkedAt = entry.checkedAt, (0..<gap).contains(now.timeIntervalSince(checkedAt)) {
            return .recent
        }
        return .ask
    }

    /// The entry marked as being checked now, written before asking.
    static func claim(_ entry: ClaudeUsageCacheEntry?, now: Date) -> ClaudeUsageCacheEntry {
        var claimed = entry ?? ClaudeUsageCacheEntry()
        claimed.checkedAt = now
        return claimed
    }

    /// The entry after asking. `email` is the profile's, when it answered.
    static func record(_ outcome: ClaudeUsageOutcome, in entry: ClaudeUsageCacheEntry?, email: String?, now: Date) -> ClaudeUsageCacheEntry? {
        var updated = entry.flatMap { sameAccount($0, email: email) ? $0 : nil } ?? ClaudeUsageCacheEntry()
        switch outcome {
        case .read(let windows, let notes):
            return ClaudeUsageCacheEntry(windows: windows, notes: notes, readAt: now, checkedAt: now, email: email)
        case .rateLimited(let retryAfter):
            updated.checkedAt = now
            updated.pausedUntil = pauseEnd(retryAfter: retryAfter, now: now)
        case .unavailable:
            updated.checkedAt = now
        case .failed:
            // A login problem has to keep showing until it's fixed, not hide behind the old reading
            // for 10 minutes, so the next refresh asks again.
            updated.checkedAt = nil
        case .paused, .recent:
            return entry
        }
        if updated.email == nil { updated.email = email }
        return updated
    }

    /// False only when both emails are known and differ.
    static func sameAccount(_ entry: ClaudeUsageCacheEntry, email: String?) -> Bool {
        guard let cached = entry.email, let email else { return true }
        return cached.caseInsensitiveCompare(email) == .orderedSame
    }

    /// Retry-After as a number of seconds. The HTTP-date form, or anything else, waits 15 minutes.
    static func pauseEnd(retryAfter: String?, now: Date) -> Date {
        let text = retryAfter?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(text) else {
            return now.addingTimeInterval(defaultPause)
        }
        return now.addingTimeInterval(min(seconds, longestPause))
    }

    /// Drops limits that have reset since they were read: their old percentage is wrong now.
    static func current(_ windows: [LimitWindow], now: Date) -> [LimitWindow] {
        windows.filter { window in window.resetsAt.map { $0 > now } ?? true }
    }

    /// The cached reading with any limit that has reset dropped, or nil when there's nothing true
    /// left to show. A reading that never had any limits still counts.
    static func lastReading(_ entry: ClaudeUsageCacheEntry?, now: Date) -> ClaudeUsageCacheEntry? {
        guard var entry, entry.readAt != nil else { return nil }
        let windows = current(entry.windows, now: now)
        if windows.isEmpty, !entry.windows.isEmpty { return nil }
        entry.windows = windows
        return entry
    }
}

/// `claude-usage-cache.json`: one entry per Claude login, keyed by its Keychain service. Each change
/// re-reads the file under a lock and rewrites only that login's entry, then renames the new file
/// into place, so the app and a `token-stats limits` run writing at once can't corrupt it or lose
/// each other's changes. A cache that can't be read or written counts as empty and never stops a
/// refresh.
struct ClaudeUsageCache: Sendable {
    let url: URL

    static let standard = ClaudeUsageCache(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Stats/claude-usage-cache.json")
    )

    func entry(for key: String) -> ClaudeUsageCacheEntry? {
        Self.entry(key, in: readDocument())
    }

    /// Applies `change` to the login's latest entry and saves the result. Returns the new entry,
    /// even when it couldn't be saved.
    @discardableResult
    func update(_ key: String, _ change: (ClaudeUsageCacheEntry?) -> ClaudeUsageCacheEntry?) -> ClaudeUsageCacheEntry? {
        withLock { locked in
            var document = readDocument()
            let current = Self.entry(key, in: document)
            let updated = change(current)
            // Writing without the lock could undo another process's change, so it's skipped.
            guard locked, updated != current else { return updated }
            var accounts = document["accounts"] as? [String: Any] ?? [:]
            accounts[key] = updated.flatMap(Self.object)
            document["accounts"] = accounts
            document["version"] = 1
            if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                // Foundation writes a temporary file beside it, then renames it over the old one.
                try? data.write(to: url, options: .atomic)
            }
            return updated
        }
    }

    private func readDocument() -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func entry(_ key: String, in document: [String: Any]) -> ClaudeUsageCacheEntry? {
        guard let object = (document["accounts"] as? [String: Any])?[key] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeUsageCacheEntry.self, from: data)
    }

    private static func object(_ entry: ClaudeUsageCacheEntry) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entry)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// An exclusive `flock` on `claude-usage-cache.json.lock` while the file is read and rewritten,
    /// which takes milliseconds. The system lets it go if the process dies, so it can't go stale.
    /// After two seconds this carries on without it rather than hold up a refresh.
    private func withLock<T>(_ body: (_ locked: Bool) -> T) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return body(false) }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(2)
        var locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        while !locked, Date() < deadline {
            usleep(10_000)
            locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        }
        defer { if locked { flock(descriptor, LOCK_UN) } }
        return body(locked)
    }
}
