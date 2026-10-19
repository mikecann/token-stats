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
    var detail: String? = nil

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// A word or two that fits under a gauge in the menu.
    var shortTitle: String {
        switch title {
        case "5-hour": return "5 hour"
        case "Weekly": return "week"
        default: return title.count > 9 ? String(title.prefix(8)) + "…" : title
        }
    }
}

struct LimitAccount: Identifiable, Equatable, Sendable {
    let id: String
    let provider: LimitProvider
    var email: String?
    var plan: String?
    /// Where the login lives, e.g. `~/.codex`.
    var source: String
    /// The login folder Token Stats made for this account, if it made one.
    var folder: URL? = nil
    var windows: [LimitWindow] = []
    var notes: [String] = []
    var error: String?
    var fetchedAt: Date = Date()

    var displayName: String { email ?? source }

    /// The 5-hour and weekly limits for the menu, plus anything else that's nearly used up.
    var glanceWindows: [LimitWindow] {
        var picked = mainWindows
        if let nearlyGone = windows.filter({ !picked.contains($0) }).min(by: { $0.remainingPercent < $1.remainingPercent }),
           nearlyGone.remainingPercent < 25 {
            picked.append(nearlyGone)
        }
        return picked
    }

    /// The main rate limits: 5-hour and weekly, or whatever single limit the plan has.
    /// Dollar allowances and per-model limits aren't counted here.
    var mainWindows: [LimitWindow] {
        let main = windows.filter { $0.title == "5-hour" || $0.title == "Weekly" }
        return main.isEmpty ? Array(windows.prefix(1)) : main
    }

    /// The main limit closest to running out, which is what the menu bar shows.
    var tightestWindow: LimitWindow? { mainWindows.min { $0.remainingPercent < $1.remainingPercent } }
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
        var words = raw.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init)
        if words.first == "claude", words.count > 1 { words.removeFirst() }
        if words.starts(with: ["muse", "code"]), words.count > 2 { words.removeFirst(2) }
        return words.joined(separator: " ").capitalized
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
        "seven_day_sonnet": "Weekly Sonnet", "seven_day_oauth_apps": "Weekly apps"
    ]

    static func windows(from usage: [String: Any]) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let limits = usage["limits"] as? [[String: Any]], !limits.isEmpty {
            // Newer responses list every limit with its kind and what it's scoped to.
            for (index, limit) in limits.enumerated() {
                guard let used = CodexLimitsParser.number(limit["percent"]) else { continue }
                let kind = limit["kind"] as? String ?? "limit"
                windows.append(LimitWindow(
                    id: "limits.\(index).\(kind)", title: title(kind: kind, scope: limit["scope"] as? [String: Any]),
                    usedPercent: used, resetsAt: LimitFormat.isoDate(limit["resets_at"])
                ))
            }
        } else {
            let keys = usage.keys.filter { titles[$0] != nil }.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            for key in keys {
                guard let window = usage[key] as? [String: Any], let used = CodexLimitsParser.number(window["utilization"]) else { continue }
                windows.append(LimitWindow(id: key, title: titles[key]!, usedPercent: used, resetsAt: LimitFormat.isoDate(window["resets_at"])))
            }
        }
        // Dollar allowances turn up under code names, so they're spotted by their shape.
        for key in usage.keys.sorted() {
            guard let window = usage[key] as? [String: Any],
                  let limit = CodexLimitsParser.number(window["limit_dollars"]),
                  let used = CodexLimitsParser.number(window["utilization"]) else { continue }
            let remaining = CodexLimitsParser.number(window["remaining_dollars"])
            windows.append(LimitWindow(
                id: key, title: "\(dollars(limit)) allowance", usedPercent: used,
                resetsAt: LimitFormat.isoDate(window["resets_at"]),
                detail: remaining.map { "\(dollars($0)) left" }
            ))
        }
        return windows
    }

    static func notes(from usage: [String: Any]) -> [String] {
        guard let spend = usage["spend"] as? [String: Any], spend["enabled"] as? Bool == true,
              let used = spend["used"] as? [String: Any], let minor = CodexLimitsParser.number(used["amount_minor"]), minor > 0 else { return [] }
        let exponent = CodexLimitsParser.number(used["exponent"]) ?? 2
        return ["\(dollars(minor / pow(10, exponent))) extra usage spent"]
    }

    private static func title(kind: String, scope: [String: Any]?) -> String {
        let base: String
        switch kind {
        case "session": base = "5-hour"
        case "weekly_all", "weekly_scoped", "weekly": base = "Weekly"
        default: base = kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let names = ["model", "surface"].compactMap { (scope?[$0] as? [String: Any])?["display_name"] as? String }
        return ([base] + names).joined(separator: " ")
    }

    private static func dollars(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
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

/// One card per real account: logins for the same email are the same plan.
enum LimitAccountMerger {
    /// Keeps the login you set up yourself (`~/.claude`, `~/.codex`), then ones Token Stats made,
    /// and returns the extra logins so they can be tidied away.
    static func merge(_ accounts: [LimitAccount]) -> (kept: [LimitAccount], duplicates: [LimitAccount]) {
        var kept: [LimitAccount] = []
        var duplicates: [LimitAccount] = []
        let ordered = accounts.sorted { rank($0) < rank($1) }
        for account in ordered {
            guard let email = account.email?.lowercased(),
                  let index = kept.firstIndex(where: { $0.provider == account.provider && $0.email?.lowercased() == email }) else {
                kept.append(account)
                continue
            }
            // A login that's working beats one that errored.
            if kept[index].error != nil, account.error == nil {
                duplicates.append(kept[index])
                kept[index] = account
            } else {
                duplicates.append(account)
            }
        }
        return (kept, duplicates)
    }

    private static func rank(_ account: LimitAccount) -> (Int, String) {
        let tier = account.source.hasPrefix("~/") ? 0 : account.folder != nil ? 1 : 2
        return (tier, account.source)
    }
}

/// Reads Grok's `/billing?format=credits` response. It's protobuf JSON, which leaves out
/// zero values, so a missing `creditUsagePercent` means nothing used yet.
enum GrokLimitsParser {
    static func apply(_ billing: [String: Any], to target: inout LimitAccount) {
        let config = billing["config"] as? [String: Any] ?? billing
        if let tier = config["subscription_tier"] as? String ?? billing["subscription_tier"] as? String {
            target.plan = LimitFormat.plan(tier)
        }
        let period = config["currentPeriod"] as? [String: Any]
        guard period != nil || config["creditUsagePercent"] != nil else { return }
        let title: String
        switch (period?["type"] as? String ?? "").uppercased() {
        case let type where type.contains("WEEK"): title = "Weekly"
        case let type where type.contains("MONTH"): title = "Monthly"
        case let type where type.contains("DAY"): title = "Daily"
        default: title = "Credits"
        }
        target.windows = [LimitWindow(
            id: "credits", title: title,
            usedPercent: CodexLimitsParser.number(config["creditUsagePercent"]) ?? 0,
            resetsAt: LimitFormat.isoDate(period?["end"] ?? config["billingPeriodEnd"])
        )]
        if let onDemand = CodexLimitsParser.number((config["onDemandUsed"] as? [String: Any])?["val"]), onDemand > 0 {
            target.notes.append("\(Int(onDemand)) on-demand credits used")
        }
    }
}

/// Reads the `subs_usage` part of Muse's key response.
enum MuseLimitsParser {
    static func apply(_ response: [String: Any], to target: inout LimitAccount) {
        let usage = response["subs_usage"] as? [String: Any] ?? response["usage"] as? [String: Any] ?? [:]
        target.plan = LimitFormat.plan(response["subs_tier_name"] as? String ?? usage["tier"] as? String)
        var windows: [LimitWindow] = []
        if let window = usage["window"] as? [String: Any], let used = CodexLimitsParser.number(window["used_percent"] ?? window["usedPercent"]) {
            let minutes = CodexLimitsParser.number(window["window_duration_mins"] ?? window["windowDurationMins"]).map { Int($0) }
            windows.append(LimitWindow(id: "window", title: LimitFormat.windowTitle(minutes: minutes ?? 300), usedPercent: used,
                                       resetsAt: LimitFormat.isoDate(window["resets_at"] ?? window["resetsAtMs"])))
        }
        if let weekly = usage["weekly"] as? [String: Any], let used = CodexLimitsParser.number(weekly["used_percent"] ?? weekly["usedPercent"]) {
            windows.append(LimitWindow(id: "weekly", title: "Weekly", usedPercent: used,
                                       resetsAt: LimitFormat.isoDate(weekly["resets_at"] ?? weekly["resetsAtMs"])))
        }
        target.windows = windows
        if windows.isEmpty {
            target.notes.append(response["is_subs_active"] as? Bool == false
                ? "No active Muse subscription"
                : "Muse didn't report usage this time. It usually does once you've used it in the current window.")
        }
    }

    static func accessToken(in json: Any) -> String? {
        if let object = json as? [String: Any] {
            for key in ["access_token", "accessToken"] { if let token = object[key] as? String, !token.isEmpty { return token } }
            for value in object.values { if let token = accessToken(in: value) { return token } }
        }
        if let array = json as? [Any] { for value in array { if let token = accessToken(in: value) { return token } } }
        return nil
    }

    /// The response's shape with every secret-looking value blanked, for debugging.
    static func redacted(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: object.map { key, inner in
                let secret = key.lowercased().contains("key") || key.lowercased().contains("token") || key.lowercased().contains("secret")
                return (key, secret ? "<redacted>" as Any : redacted(inner))
            })
        }
        if let array = value as? [Any] { return array.map(redacted) }
        return value
    }
}

enum LoginRenewal {
    /// The login being turned down means signing in again. Anything else, like a rate limit or
    /// no connection, is worth another go at the next check.
    static func failureMessage(status: Int, reason: String?, signInAgain: String) -> String {
        if [400, 401, 403].contains(status) {
            return "Sign-in expired and couldn't be renewed (\(reason ?? "HTTP \(status)")). \(signInAgain)"
        }
        let detail = status > 0 ? "HTTP \(status)\(reason.map { ": \($0)" } ?? "")" : reason ?? "no answer"
        return "Couldn't renew this sign-in just now (\(detail)). Token Stats tries again in a few minutes."
    }
}

/// Renews a Claude Code login the same way Claude Code does. Claude Code only renews a login
/// while it's running with it, so logins that aren't used in a terminal on this Mac (the ones
/// Token Stats added, and the main one when Claude Code only runs in the desktop app) lapse
/// within hours.
enum ClaudeLoginRenewal {
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Renewing a little early means a card never shows a lapsed login between 5-minute checks.
    static let margin: TimeInterval = 10 * 60

    static func request(refreshToken: String, scopes: [String]?) -> URLRequest {
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Not Claude Code's User-Agent: this endpoint answers 429 to that straight away.
        request.setValue("Token Stats", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Claude Code's own renewal lock for a login, a folder it makes inside the login's config
    /// folder. Taking the same one means Token Stats and a running `claude` never renew at once.
    static func lockURL(configDir: URL) -> URL {
        configDir.appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
    }

    /// The config folder a saved login belongs to, which is where its lock lives. Nil for logins
    /// made with some other `CLAUDE_CONFIG_DIR`, which are left alone.
    static func configDir(service: String, folder: URL?, home: URL, environment: [String: String]) -> URL? {
        if let folder { return folder }
        guard service == ClaudeLimitsClient.servicePrefix else { return nil }
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The saved login with the new tokens and expiry in place, or nil if the answer has no token.
    static func renewed(_ saved: [String: Any], with response: [String: Any], now: Date) -> [String: Any]? {
        guard var oauth = saved["claudeAiOauth"] as? [String: Any],
              let access = response["access_token"] as? String, !access.isEmpty,
              let lifetime = (response["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        oauth["accessToken"] = access
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + lifetime) * 1000)
        if let scope = response["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        var updated = saved
        updated["claudeAiOauth"] = oauth
        return updated
    }

    /// JSON with anything outside ASCII escaped, because `security -w` prints a secret holding
    /// other bytes as hex, and Claude Code (and Token Stats) would then fail to read it back.
    static func asciiJSON(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        var text = ""
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if scalar.isASCII {
                text.unicodeScalars.append(scalar)
            } else {
                for unit in String(scalar).utf16 { text += String(format: "\\u%04x", unit) }
            }
        }
        return Data(text.utf8)
    }

    /// The `acct` attribute from `security find-generic-password` output, so the save
    /// updates the same Keychain item instead of adding a second one.
    static func keychainAccount(fromAttributes output: String) -> String? {
        guard let range = output.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression) else { return nil }
        return String(output[range].dropFirst(#""acct"<blob>=""#.count).dropLast())
    }

    /// The longest line `security -i` reads.
    static let saveLineLimit = 4032

    /// A line for `security -i`, which keeps the login out of the process list.
    static func saveCommand(account: String, service: String, secret: Data) -> String {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(quoted(hex))\n"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Renews Grok's login the way Grok does: an OAuth refresh at the issuer saved in `auth.json`.
/// Grok only renews while it's running, so without this its card lapses within hours.
enum GrokLoginRenewal {
    static let margin: TimeInterval = 10 * 60
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func request(tokenEndpoint: URL, refreshToken: String, clientID: String) -> URLRequest {
        let fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)]
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $1)" }
            .joined(separator: "&").utf8)
        return request
    }

    /// The login entry with the new token and expiry, or nil if the answer has no token.
    static func renewed(_ login: [String: Any], with response: [String: Any], now: Date) -> [String: Any]? {
        guard let access = response["access_token"] as? String, !access.isEmpty,
              let lifetime = (response["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        var updated = login
        updated["key"] = access
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { updated["refresh_token"] = refresh }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updated["expires_at"] = formatter.string(from: now.addingTimeInterval(lifetime))
        return updated
    }

    /// Grok writes `pid:unix-seconds` into `auth.json.lock` while it holds it.
    static func lockContents(pid: Int32, now: Date) -> String {
        "\(pid):\(Int(now.timeIntervalSince1970))"
    }
}
