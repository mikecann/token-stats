import AppKit
import Foundation

/// Keeps every plan's limits fresh for the menu bar and the dashboard.
@MainActor
final class LimitsStore: ObservableObject {
    static let shared = LimitsStore()

    @Published private(set) var accounts: [LimitAccount] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// A short message for the menu, e.g. that a newly added login was already there.
    @Published private(set) var notice: String?

    private var timer: Timer?
    private var signInWatcher: Task<Void, Never>?
    private let fileManager = FileManager.default

    /// Extra logins made from Token Stats live here, one folder per account.
    var accountsDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Stats/Accounts", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor in LimitsStore.shared.refresh() }
        }
    }

    /// Refreshes when the menu opens, unless it just did.
    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        refresh()
    }

    func refresh(only providers: Set<LimitProvider>? = nil) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let include = { (provider: LimitProvider) in providers?.contains(provider) ?? true }
        let codexHomes = include(.codex) ? codexHomes() : []
        let claudeLabels = include(.claude) ? claudeLabels() : [:]
        let others = OtherAgentLimits.fetchers.filter { include($0.provider) }.map(\.fetch)
        Task {
            // Each account shows up as soon as it answers, so one waiting on a Keychain prompt doesn't hold up the rest.
            var fresh: [String: LimitAccount] = [:]
            await withTaskGroup(of: [LimitAccount].self) { group in
                for (home, label, folder) in codexHomes {
                    group.addTask { [await CodexLimitsClient.fetch(home: home, label: label, folder: folder)] }
                }
                if !claudeLabels.isEmpty {
                    group.addTask {
                        let services = await Task.detached { ClaudeLimitsClient.savedServices() }.value
                        return await withTaskGroup(of: LimitAccount.self) { inner in
                            for service in services {
                                let login = claudeLabels[service] ?? ("Other Claude Code login", nil)
                                inner.addTask { await ClaudeLimitsClient.fetch(service: service, label: login.0, folder: login.1) }
                            }
                            var all: [LimitAccount] = []
                            for await account in inner { all.append(account) }
                            return all
                        }
                    }
                }
                for fetch in others {
                    group.addTask { [await fetch()] }
                }
                for await batch in group {
                    batch.forEach { fresh[$0.id] = $0 }
                    let keep = accounts.filter { fresh[$0.id] == nil && !(providers?.contains($0.provider) == false) }
                    accounts = Self.sorted(LimitAccountMerger.merge(keep + Array(fresh.values)).kept)
                }
            }
            // Accounts that no longer exist drop off once everything has answered.
            let merged = LimitAccountMerger.merge(Array(fresh.values) + accounts.filter { providers?.contains($0.provider) == false })
            accounts = Self.sorted(merged.kept)
            removeDuplicateLogins(merged.duplicates)
            lastRefresh = Date()
            isRefreshing = false
        }
    }

    /// The plan with the least left, shown next to the menu bar icon.
    var tightest: (account: LimitAccount, window: LimitWindow)? {
        accounts.compactMap { account in account.tightestWindow.map { (account, $0) } }
            .min { $0.1.remainingPercent < $1.1.remainingPercent }
    }

    /// Opens Terminal on a login command that saves the new account in its own folder.
    func addAccount(_ provider: LimitProvider) {
        let number = (1...99).first { !fileManager.fileExists(atPath: folder(provider, $0).path) } ?? 99
        let loginFolder = folder(provider, number)
        try? fileManager.createDirectory(at: loginFolder, withIntermediateDirectories: true)
        let quoted = "'\(loginFolder.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let command: String
        switch provider {
        case .codex:
            command = """
            echo "Sign in with the ChatGPT account you want to add. If the browser picks the wrong one, switch accounts there first."
            CODEX_HOME=\(quoted) codex login
            """
        case .claude:
            command = """
            echo "Sign in with the Claude account you want to add. If the browser picks the wrong one, switch accounts there first."
            CLAUDE_CONFIG_DIR=\(quoted) claude auth login
            """
        default:
            return
        }
        let script = loginFolder.appendingPathComponent("sign-in.command")
        let body = """
        #!/bin/zsh -l
        \(command)
        echo
        echo "Done. Token Stats will show it in a few seconds. You can close this window."
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
        notice = nil
        watchForSignIn(provider, folder: loginFolder)
    }

    /// Refreshes by itself as soon as the new login lands, so there's nothing to click.
    private func watchForSignIn(_ provider: LimitProvider, folder: URL) {
        signInWatcher?.cancel()
        signInWatcher = Task {
            let deadline = Date().addingTimeInterval(15 * 60)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                let signedIn: Bool
                switch provider {
                case .codex:
                    signedIn = fileManager.fileExists(atPath: folder.appendingPathComponent("auth.json").path)
                default:
                    let service = ClaudeLimitsClient.serviceName(configDir: folder)
                    signedIn = await Task.detached { ClaudeLimitsClient.savedServices().contains(service) }.value
                }
                guard signedIn else { continue }
                while isRefreshing { try? await Task.sleep(for: .milliseconds(300)) }
                refresh()
                return
            }
        }
    }

    /// Two logins for the same email are the same plan, so the extra one is signed out and its
    /// folder removed. Only logins Token Stats made are touched; `~/.claude` and `~/.codex` never are.
    private func removeDuplicateLogins(_ duplicates: [LimitAccount]) {
        var removed: [String] = []
        for duplicate in duplicates {
            if duplicate.provider == .claude, duplicate.id.hasPrefix("claude:") {
                let service = String(duplicate.id.dropFirst("claude:".count))
                guard service != ClaudeLimitsClient.serviceName(configDir: nil) else { continue }
                _ = ProcessRunner.run(["/usr/bin/security", "delete-generic-password", "-s", service], timeout: 15)
            }
            if let folder = duplicate.folder, folder.deletingLastPathComponent().standardizedFileURL == accountsDirectory.standardizedFileURL {
                try? fileManager.removeItem(at: folder)
            }
            if let email = duplicate.email { removed.append(email) }
        }
        if !removed.isEmpty {
            notice = "\(Set(removed).sorted().joined(separator: ", ")) was already added, so the extra sign-in was removed."
        }
    }

    private func folder(_ provider: LimitProvider, _ number: Int) -> URL {
        accountsDirectory.appendingPathComponent("\(provider.rawValue.lowercased())-\(number)", isDirectory: true)
    }

    private func codexHomes() -> [(URL, String, URL?)] {
        let home = fileManager.homeDirectoryForCurrentUser
        var homes: [(URL, String, URL?)] = []
        let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        let main = environmentHome ?? home.appendingPathComponent(".codex")
        if fileManager.fileExists(atPath: main.appendingPathComponent("auth.json").path) {
            homes.append((main, "~/.codex", nil))
        }
        for folder in extraFolders(prefix: "codex-") where fileManager.fileExists(atPath: folder.appendingPathComponent("auth.json").path) {
            homes.append((folder, folder.lastPathComponent, folder))
        }
        return homes
    }

    private func claudeLabels() -> [String: (String, URL?)] {
        var labels: [String: (String, URL?)] = [ClaudeLimitsClient.serviceName(configDir: nil): ("~/.claude", nil)]
        for folder in extraFolders(prefix: "claude-") {
            labels[ClaudeLimitsClient.serviceName(configDir: folder)] = (folder.lastPathComponent, folder)
        }
        return labels
    }

    private func extraFolders(prefix: String) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: accountsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func sorted(_ accounts: [LimitAccount]) -> [LimitAccount] {
        let order = LimitProvider.allCases
        return accounts.sorted {
            let left = order.firstIndex(of: $0.provider) ?? 0, right = order.firstIndex(of: $1.provider) ?? 0
            return left == right ? $0.displayName < $1.displayName : left < right
        }
    }
}

/// Grok and Muse readers plug in here.
enum OtherAgentLimits {
    static var fetchers: [(provider: LimitProvider, fetch: @Sendable () async -> LimitAccount)] { [] }
}

/// `token-stats limits` prints every plan's limits and exits, without starting the app.
enum LimitsCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--update-clis" {
            let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Token Stats/cli-updates.log")
            let results = CLIUpdater.updateAll(logURL: logURL)
            CLIUpdater.record(results)
            for result in results { print(result.summary) }
            print("Full output: \(logURL.path)")
            exit(0)
        }
        guard arguments.first == "--limits" else { return }
        let only = arguments.dropFirst().compactMap { LimitProvider(rawValue: $0.capitalized) }
        Task { @MainActor in
            let store = LimitsStore.shared
            store.refresh(only: only.isEmpty ? nil : Set(only))
            let deadline = Date().addingTimeInterval(45)
            while store.isRefreshing, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if store.isRefreshing { print("(Some accounts didn't answer within 45s. A Keychain prompt may be waiting.)") }
            for account in store.accounts {
                print("\(account.provider.rawValue) \(account.plan ?? "") \(account.displayName) [\(account.source)]")
                if let error = account.error { print("  ! \(error)") }
                for window in account.windows {
                    let extra = [window.detail, LimitFormat.resetText(window.resetsAt)].compactMap { $0 }.filter { !$0.isEmpty }
                    print("  \(window.title): \(Int(window.remainingPercent.rounded()))% left \(extra.joined(separator: ", "))")
                }
                if !account.notes.isEmpty { print("  \(account.notes.joined(separator: " · "))") }
            }
            if store.accounts.isEmpty { print("No signed-in plans found.") }
            if let notice = store.notice { print(notice) }
            exit(0)
        }
        RunLoop.main.run()
    }
}
