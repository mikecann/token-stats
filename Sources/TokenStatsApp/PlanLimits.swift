import Foundation
import SwiftUI

/// Subscription plans whose usage limits Token Stats can read.
enum LimitProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case grok = "Grok"
    case muse = "Muse"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .codex: return UsageProvider.codex.color
        case .claude: return UsageProvider.claude.color
        case .grok: return Color(red: 0.86, green: 0.86, blue: 0.90)
        case .muse: return Color(red: 0.35, green: 0.55, blue: 1.0)
        }
    }

    var symbol: String {
        switch self {
        case .codex: return UsageProvider.codex.symbol
        case .claude: return UsageProvider.claude.symbol
        case .grok: return "xmark"
        case .muse: return "infinity"
        }
    }
}

struct LimitWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct LimitAccount: Identifiable, Equatable, Sendable {
    let id: String
    let provider: LimitProvider
    var email: String?
    var plan: String?
    /// Where the login lives, e.g. `~/.codex`.
    var source: String
    var windows: [LimitWindow] = []
    var notes: [String] = []
    var error: String?
    var fetchedAt: Date = Date()

    var displayName: String { email ?? source }

    /// The window closest to running out, which is what the menu bar shows.
    var tightestWindow: LimitWindow? { windows.min { $0.remainingPercent < $1.remainingPercent } }
}

enum LimitFormat {
    static func windowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage" }
        switch minutes {
        case 10080: return "Weekly"
        case 1440: return "Daily"
        case 43200, 44640: return "Monthly"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        let names = [
            "pro": "Pro", "plus": "Plus", "free": "Free", "go": "Go", "team": "Team",
            "prolite": "Pro Lite", "promax": "Pro Max", "business": "Business", "enterprise": "Enterprise",
            "max": "Max", "claude_max": "Max", "claude_pro": "Pro", "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        ]
        if let name = names[raw.lowercased()] { return name }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "resets in \(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "resets in \(hours)h \(minutes % 60)m" }
        return "resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// Parses ISO 8601 dates with or without fractional seconds of any length.
    static func isoDate(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        if let number = value as? Int { return Date(timeIntervalSince1970: TimeInterval(number > 1_000_000_000_000 ? number / 1000 : number)) }
        guard var text = value as? String, !text.isEmpty else { return nil }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) { text.removeSubrange(range) }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Reads the `account/read` and `account/rateLimits/read` responses from `codex app-server`.
enum CodexLimitsParser {
    static func apply(account: [String: Any]?, rateLimits: [String: Any]?, to target: inout LimitAccount) {
        if let info = account?["account"] as? [String: Any] {
            target.email = info["email"] as? String ?? target.email
            target.plan = LimitFormat.plan(info["planType"] as? String) ?? target.plan
        } else if account != nil, account?["account"] is NSNull {
            target.error = "Not signed in"
        }
        guard let rateLimits else { return }

        var snapshots: [[String: Any]] = []
        if let byID = rateLimits["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            snapshots = byID.keys.sorted().compactMap { byID[$0] as? [String: Any] }
        } else if let single = rateLimits["rateLimits"] as? [String: Any] {
            snapshots = [single]
        }

        var windows: [LimitWindow] = []
        for snapshot in snapshots {
            let limitID = snapshot["limitId"] as? String ?? "codex"
            let name = (snapshot["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if target.plan == nil { target.plan = LimitFormat.plan(snapshot["planType"] as? String) }
            for key in ["primary", "secondary"] {
                guard let window = snapshot[key] as? [String: Any], let used = number(window["usedPercent"]) else { continue }
                let base = LimitFormat.windowTitle(minutes: (number(window["windowDurationMins"])).map { Int($0) })
                windows.append(LimitWindow(
                    id: "\(limitID).\(key)",
                    title: name.map { "\(base) \($0)" } ?? base,
                    usedPercent: used,
                    resetsAt: LimitFormat.isoDate(window["resetsAt"])
                ))
            }
            if let credits = snapshot["credits"] as? [String: Any], credits["hasCredits"] as? Bool == true,
               let balance = number(credits["balance"]), balance > 0, limitID == "codex" {
                target.notes.append("\(Int(balance).formatted()) credits")
            }
        }
        if let resets = rateLimits["rateLimitResetCredits"] as? [String: Any],
           let count = number(resets["availableCount"]), count > 0 {
            target.notes.append("\(Int(count)) limit reset\(count == 1 ? "" : "s") available")
        }
        if rateLimits["ordinaryUsageAllowed"] as? Bool == false {
            target.notes.append("Limit reached")
        }
        target.windows = windows
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

/// Reads Claude's `/api/oauth/usage` and `/api/oauth/profile` responses.
enum ClaudeLimitsParser {
    private static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"]
    private static let titles = [
        "five_hour": "5-hour", "seven_day": "Weekly", "seven_day_opus": "Weekly Opus",
        "seven_day_sonnet": "Weekly Sonnet", "seven_day_oauth_apps": "Weekly apps", "extra_usage": "Extra usage"
    ]

    static func windows(from usage: [String: Any]) -> [LimitWindow] {
        let keys = usage.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return keys.compactMap { key in
            guard let window = usage[key] as? [String: Any],
                  let used = CodexLimitsParser.number(window["utilization"]) else { return nil }
            if window["is_enabled"] as? Bool == false { return nil }
            let title = titles[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            return LimitWindow(id: key, title: title, usedPercent: used, resetsAt: LimitFormat.isoDate(window["resets_at"]))
        }
    }

    static func apply(profile: [String: Any], to target: inout LimitAccount) {
        if let account = profile["account"] as? [String: Any] {
            target.email = account["email_address"] as? String ?? account["email"] as? String ?? target.email
        }
        if let organization = profile["organization"] as? [String: Any],
           let type = organization["organization_type"] as? String ?? organization["rate_limit_tier"] as? String {
            target.plan = LimitFormat.plan(type) ?? target.plan
        }
    }
}
