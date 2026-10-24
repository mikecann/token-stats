import Foundation

/// The versioned format shared by the CLI and the app's limits snapshot.
enum LimitsJSON {
    /// `complete` is false when some providers hadn't answered yet, so the list may be missing accounts.
    static func encode(_ accounts: [LimitAccount], generatedAt: Date, complete: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(generatedAt: generatedAt, complete: complete, accounts: accounts.map { Account(account: $0) }))
    }

    /// Always writes, even with no accounts, so removing the last login doesn't leave a stale file behind.
    static func writeSnapshot(_ accounts: [LimitAccount], generatedAt: Date, to url: URL) throws {
        let data = try encode(accounts, generatedAt: generatedAt)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Foundation writes a temporary file beside the destination, then renames it over it.
        try data.write(to: url, options: .atomic)
    }

    private struct Document: Encodable {
        let version = 1
        let generatedAt: Date
        let complete: Bool
        let accounts: [Account]
    }

    private struct Account: Encodable {
        let account: LimitAccount

        private enum CodingKeys: String, CodingKey {
            case provider, plan, email, configDir, label, windows, notice, usageReadAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(account.provider, forKey: .provider)
            // Encode optional values explicitly so missing data is null, rather than an absent key.
            try container.encode(account.plan, forKey: .plan)
            try container.encode(account.email, forKey: .email)
            try container.encode((account.configDir ?? account.folder)?.standardizedFileURL.path, forKey: .configDir)
            try container.encode(account.source.isEmpty ? nil : account.source, forKey: .label)
            try container.encode(account.windows.map { Window(window: $0) }, forKey: .windows)
            let messages = ([account.error].compactMap { $0 } + account.notes).filter { !$0.isEmpty }
            try container.encode(messages.isEmpty ? nil : messages.joined(separator: " · "), forKey: .notice)
            // When these numbers came from the provider. Claude's can be an earlier reading, and
            // `notice` says so when that matters; the others are read on every check.
            try container.encode(account.usageReadAt ?? (account.windows.isEmpty ? nil : account.fetchedAt), forKey: .usageReadAt)
        }
    }

    private struct Window: Encodable {
        let window: LimitWindow

        private enum CodingKeys: String, CodingKey {
            case kind, title, remainingPercent, resetsAt, detail
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(window.title, forKey: .title)
            try container.encode(window.remainingPercent, forKey: .remainingPercent)
            try container.encode(window.resetsAt, forKey: .resetsAt)
            try container.encode(window.detail, forKey: .detail)
        }

        private var kind: String {
            switch window.title {
            case "5-hour": return "five_hour"
            case "Weekly": return "weekly"
            case "Daily": return "daily"
            case "Monthly": return "monthly"
            default:
                // Parsers append model/surface names to scoped windows, including Codex's.
                if window.title.hasPrefix("5-hour ") { return "five_hour" }
                if window.title.hasPrefix("Weekly ") { return "weekly_model" }
                if window.title.hasPrefix("$"), window.title.hasSuffix(" allowance") { return "allowance" }
                return "other"
            }
        }
    }
}
