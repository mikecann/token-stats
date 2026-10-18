import CryptoKit
import Foundation
import Security

/// Asks `codex app-server` for the signed-in account and its rate limits.
/// Each account is a separate `CODEX_HOME`, so this works for any number of logins.
enum CodexLimitsClient {
    static func fetch(home: URL, label: String, folder: URL?) async -> LimitAccount {
        var account = LimitAccount(id: "codex:\(home.path)", provider: .codex, source: label, folder: folder)
        guard let executable = CommandLocator.find("codex") else {
            account.error = "Couldn't find the codex command"
            return account
        }
        do {
            let responses = try await JSONRPCSession.run(
                executable: executable,
                arguments: ["app-server"],
                environment: ["CODEX_HOME": home.path],
                requests: [
                    ["id": 2, "method": "account/read", "params": [String: Any]()],
                    ["id": 3, "method": "account/rateLimits/read"]
                ]
            )
            if let error = responses[3]?["error"] as? [String: Any] {
                account.error = error["message"] as? String ?? "Codex couldn't read limits"
            }
            CodexLimitsParser.apply(
                account: responses[2]?["result"] as? [String: Any],
                rateLimits: responses[3]?["result"] as? [String: Any],
                to: &account
            )
        } catch {
            account.error = error.localizedDescription
        }
        return account
    }
}

/// Reads Claude Code's saved logins from the Keychain and asks Anthropic for each one's usage.
/// Claude Code stores the default login as `Claude Code-credentials` and logins made with
/// `CLAUDE_CONFIG_DIR` under the same name plus a short hash of that folder.
enum ClaudeLimitsClient {
    static let servicePrefix = "Claude Code-credentials"

    static func serviceName(configDir: URL?) -> String {
        guard let configDir else { return servicePrefix }
        let digest = SHA256.hash(data: Data(configDir.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(servicePrefix)-\(digest.prefix(8))"
    }

    static func savedServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let services = items.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(servicePrefix) }
        return Array(Set(services)).sorted()
    }

    static func fetch(service: String, label: String, folder: URL?) async -> LimitAccount {
        var account = LimitAccount(id: "claude:\(service)", provider: .claude, source: label, folder: folder)
        guard var oauth = readSaved(service: service)?["claudeAiOauth"] as? [String: Any] else {
            account.error = "Couldn't read this Claude login from the Keychain"
            return account
        }
        account.plan = LimitFormat.plan(oauth["subscriptionType"] as? String)
        let expires = LimitFormat.isoDate(oauth["expiresAt"])
        if let folder, let expires, expires < Date().addingTimeInterval(ClaudeLoginRenewal.margin) {
            // Only logins Token Stats made are renewed here. The main one is Claude Code's, and
            // two programs renewing the same login can sign each other out.
            do {
                oauth = try await renew(service: service, folder: folder)
            } catch let error as RenewalError {
                account.error = ClaudeLoginRenewal.failureMessage(status: error.status, reason: error.reason)
                return account
            } catch {
                account.error = ClaudeLoginRenewal.failureMessage(status: 0, reason: error.localizedDescription)
                return account
            }
        } else if let expires, expires < Date() {
            account.error = "Sign-in expired. Run claude once to refresh it."
            return account
        }
        guard let token = oauth["accessToken"] as? String else {
            account.error = "Couldn't read this Claude login from the Keychain"
            return account
        }
        do {
            async let usage = get("https://api.anthropic.com/api/oauth/usage", token: token)
            async let profile = try? get("https://api.anthropic.com/api/oauth/profile", token: token)
            let usageJSON = try await usage
            if ProcessInfo.processInfo.environment["TOKEN_STATS_DEBUG"] == "1",
               let data = try? JSONSerialization.data(withJSONObject: usageJSON, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            account.windows = ClaudeLimitsParser.windows(from: usageJSON)
            account.notes = ClaudeLimitsParser.notes(from: usageJSON)
            if let profile = await profile { ClaudeLimitsParser.apply(profile: profile, to: &account) }
        } catch {
            account.error = error.localizedDescription
        }
        return account
    }

    /// The installed Claude Code version, read from where its native installer links it.
    private static let claudeVersion: String = {
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? ""
        let version = (target as NSString).lastPathComponent
        return version.first?.isNumber == true ? version : "2.1.0"
    }()

    /// Claude Code writes its login with Apple's `security` tool, so that tool is the one the
    /// Keychain trusts to read it back. Going through it means no "allow access" prompts, even
    /// after Claude Code rewrites the item when it refreshes the login.
    private static func readSaved(service: String) -> [String: Any]? {
        let result = ProcessRunner.run(["/usr/bin/security", "find-generic-password", "-s", service, "-w"], timeout: 15)
        guard result.status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    }

    /// Swaps the refresh token for new tokens and saves them where Claude Code keeps them.
    /// A lock file in the login's folder stops the app and `token-stats limits` renewing at
    /// once, which would spend the same refresh token twice.
    private static func renew(service: String, folder: URL) async throws -> [String: Any] {
        let lock = try await FolderLock.acquire(folder.appendingPathComponent(".token-stats-renew.lock"))
        defer { lock.release() }
        guard let saved = readSaved(service: service), let oauth = saved["claudeAiOauth"] as? [String: Any] else {
            throw LimitsError("couldn't read the login")
        }
        // Someone else may have renewed it while this waited for the lock.
        if let expires = LimitFormat.isoDate(oauth["expiresAt"]), expires > Date().addingTimeInterval(ClaudeLoginRenewal.margin) {
            return oauth
        }
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw RenewalError(status: 400, reason: "no refresh token saved")
        }
        let request = ClaudeLoginRenewal.request(refreshToken: refreshToken, scopes: oauth["scopes"] as? [String])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let renewed = ClaudeLoginRenewal.renewed(saved, with: json, now: Date()) else {
            let reason = json["error_description"] as? String ?? json["error"] as? String
                ?? ((json["error"] as? [String: Any])?["message"] as? String)
            throw RenewalError(status: status, reason: reason)
        }
        try save(renewed, service: service)
        guard let stored = readSaved(service: service)?["claudeAiOauth"] as? [String: Any],
              stored["accessToken"] as? String == (renewed["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else {
            throw LimitsError("the Keychain didn't keep the renewed login")
        }
        return stored
    }

    /// Writes the login back the way Claude Code does: `security -i` with the login hex-encoded
    /// on stdin, or as an argument when it's too long for one `security -i` line.
    private static func save(_ saved: [String: Any], service: String) throws {
        let secret = try ClaudeLoginRenewal.asciiJSON(saved)
        let attributes = ProcessRunner.run(["/usr/bin/security", "find-generic-password", "-s", service], timeout: 15)
        let account = ClaudeLoginRenewal.keychainAccount(fromAttributes: attributes.output) ?? NSUserName()
        let command = ClaudeLoginRenewal.saveCommand(account: account, service: service, secret: secret)
        let result = command.utf8.count <= 4032
            ? ProcessRunner.run(["/usr/bin/security", "-i"], input: Data(command.utf8), timeout: 15)
            : ProcessRunner.run(["/usr/bin/security", "add-generic-password", "-U", "-a", account, "-s", service,
                                 "-X", secret.map { String(format: "%02x", $0) }.joined()], timeout: 15)
        guard result.status == 0 else { throw LimitsError("couldn't save the renewed login to the Keychain") }
    }

    private static func get(_ url: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(claudeVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw LimitsError("Anthropic returned \(status == 401 ? "401: sign in again" : "HTTP \(status)")\(detail.map { ": \($0)" } ?? "")")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError("Unexpected response from Anthropic")
        }
        return object
    }
}

/// An exclusive `flock` on a file, shared between the app and the `token-stats` command.
final class FolderLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ url: URL, timeout: TimeInterval = 60) async throws -> FolderLock {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw LimitsError("couldn't open \(url.lastPathComponent)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(descriptor)
                throw LimitsError("another renewal is still running")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return FolderLock(descriptor: descriptor)
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Why Anthropic turned a renewal down, so the card can say whether to wait or sign in again.
struct RenewalError: Error {
    let status: Int
    let reason: String?
}

struct LimitsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Finds CLIs that live in the user's shell PATH, which apps opened from Finder don't inherit.
enum CommandLocator {
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    static func find(_ name: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Same order as a typical shell PATH: nvm's newest node first, then Homebrew, then ~/.local/bin.
        var candidates: [String] = []
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            candidates += versions.sorted(by: >).map { "\(home)/.nvm/versions/node/\($0)/bin/\(name)" }
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
        if name == "codex" { candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex") }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        cache[name] = found
        return found
    }
}

/// Runs a newline-delimited JSON-RPC server over stdio for a handful of requests, then stops it.
enum JSONRPCSession {
    static func run(
        executable: URL,
        arguments: [String],
        environment extra: [String: String],
        requests: [[String: Any]],
        timeout: TimeInterval = 25
    ) async throws -> [Int: [String: Any]] {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // npm-installed CLIs start with `#!/usr/bin/env node`, so node's folder must be on PATH.
            environment["PATH"] = ([executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
                + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
            extra.forEach { environment[$0] = $1 }
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer {
                deadline.cancel()
                if process.isRunning { process.terminate() }
            }

            func send(_ message: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: message.merging(["jsonrpc": "2.0"]) { a, _ in a })
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
            }

            var buffer = Data()
            var responses: [Int: [String: Any]] = [:]
            func waitFor(_ ids: Set<Int>) {
                while !ids.isSubset(of: Set(responses.keys)) {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { return }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           let id = object["id"] as? Int {
                            responses[id] = object
                        }
                    }
                }
            }

            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "token-stats", "title": "Token Stats", "version": "0.2.0"]]])
            waitFor([1])
            guard responses[1] != nil else { throw LimitsError("The Codex app server didn't start") }
            try send(["method": "initialized"])
            for request in requests { try send(request) }
            let ids = Set(requests.compactMap { $0["id"] as? Int })
            waitFor(ids)
            guard ids.isSubset(of: Set(responses.keys)) else { throw LimitsError("Timed out waiting for Codex") }
            return responses
        }.value
    }
}

/// Reads Grok Build's monthly credit usage, the same call its `/usage` command makes, using
/// the login in `~/.grok/auth.json`. Token Stats never refreshes or rewrites that login.
enum GrokLimitsClient {
    static var authURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json") }

    static func fetch() async -> LimitAccount? {
        guard let data = try? Data(contentsOf: authURL),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = saved.values.compactMap({ $0 as? [String: Any] }).first(where: { $0["key"] is String }),
              let token = login["key"] as? String else { return nil }
        var account = LimitAccount(id: "grok:~/.grok", provider: .grok, email: login["email"] as? String, source: "~/.grok")
        if let expires = LimitFormat.isoDate(login["expires_at"]), expires < Date() {
            account.error = "Sign-in expired. Run grok once to refresh it."
            return account
        }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(grokVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if ProcessInfo.processInfo.environment["TOKEN_STATS_DEBUG"] == "1" {
                print("grok billing HTTP \(status): \(String(decoding: body.prefix(4000), as: UTF8.self))")
            }
            guard (200..<300).contains(status), let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw LimitsError("Grok returned HTTP \(status)")
            }
            GrokLimitsParser.apply(json, to: &account)
        } catch {
            account.error = error.localizedDescription
        }
        return account
    }

    private static let grokVersion: String = {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/version.json")
        let json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return json?["version"] as? String ?? "1.0.62"
    }()
}

/// Reads Muse's plan usage. Muse only reports it when it hands out an API key (which it does at
/// the start of every Muse session), so this asks at most once an hour and throws the key away.
enum MuseLimitsClient {
    static let service = "ai.meta.dev.credentials"
    static let interval: TimeInterval = 60 * 60
    private static let cache = MuseCache()

    static var authURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/muse/auth.json") }

    static func fetch() async -> LimitAccount? {
        guard let data = try? Data(contentsOf: authURL),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = (saved["providers"] as? [String: Any])?["meta"] as? [String: Any] else { return nil }
        if let cached = await cache.fresh(within: interval) { return cached }

        var account = LimitAccount(id: "muse:meta", provider: .muse, email: meta["user_email"] as? String, source: "~/.config/muse")
        guard let token = readToken() else {
            account.error = "Couldn't read Muse's login from the Keychain"
            return account
        }
        do {
            let response = try await mint(token: token)
            MuseLimitsParser.apply(response, to: &account)
        } catch {
            account.error = error.localizedDescription
        }
        await cache.store(account)
        return account
    }

    private static func mint(token: String) async throws -> [String: Any] {
        var lastStatus = 0
        for method in ["POST", "GET"] {
            var request = URLRequest(url: URL(string: "https://api.meta.ai/muse-code/key")!, timeoutInterval: 20)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{}".utf8)
            }
            let (body, response) = try await URLSession.shared.data(for: request)
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if ProcessInfo.processInfo.environment["TOKEN_STATS_DEBUG"] == "1" {
                // Never print the minted key itself.
                let shape = json.map { MuseLimitsParser.redacted($0) } ?? ["body": String(decoding: body.prefix(300), as: UTF8.self)]
                let text = (try? JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                print("muse \(method) HTTP \(lastStatus): \(text)")
            }
            if (200..<300).contains(lastStatus), let json { return json }
            if lastStatus != 404 && lastStatus != 405 { break }
        }
        throw LimitsError("Meta returned HTTP \(lastStatus)")
    }

    /// The Keychain item may be a bare token or JSON holding one.
    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return MuseLimitsParser.accessToken(in: json)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

actor MuseCache {
    private var account: LimitAccount?

    func fresh(within interval: TimeInterval) -> LimitAccount? {
        guard let account, account.error == nil, Date().timeIntervalSince(account.fetchedAt) < interval else { return nil }
        return account
    }

    func store(_ account: LimitAccount) { self.account = account }
}
