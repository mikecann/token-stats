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
        guard let oauth = readOAuth(service: service), let token = oauth["accessToken"] as? String else {
            account.error = "Couldn't read this Claude login from the Keychain"
            return account
        }
        account.plan = LimitFormat.plan(oauth["subscriptionType"] as? String)
        if let expires = LimitFormat.isoDate(oauth["expiresAt"]), expires < Date() {
            account.error = "Sign-in expired. Run claude with this account once to refresh it."
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
    private static func readOAuth(service: String) -> [String: Any]? {
        let result = ProcessRunner.run(["/usr/bin/security", "find-generic-password", "-s", service, "-w"], timeout: 15)
        guard result.status == 0,
              let saved = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return nil }
        return saved["claudeAiOauth"] as? [String: Any]
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
