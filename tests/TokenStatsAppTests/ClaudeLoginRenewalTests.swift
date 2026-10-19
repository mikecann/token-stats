import XCTest
@testable import TokenStatsApp

final class ClaudeLoginRenewalTests: XCTestCase {
    func testRequestSendsRefreshTokenClientAndSavedScopes() throws {
        let request = ClaudeLoginRenewal.request(refreshToken: "refresh-1", scopes: ["user:profile", "user:inference"])

        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Anthropic answers 429 straight away to a claude-code User-Agent on this endpoint.
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Token Stats")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, [
            "grant_type": "refresh_token",
            "refresh_token": "refresh-1",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference"
        ])
    }

    func testRequestLeavesScopeOutWhenTheLoginHasNone() throws {
        let request = ClaudeLoginRenewal.request(refreshToken: "refresh-1", scopes: nil)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertNil(body["scope"])
    }

    func testRenewedLoginMovesExpiryAndKeepsEverythingElse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-access", "refreshToken": "old-refresh", "expiresAt": 1_700_000_000_000,
                "scopes": ["user:profile"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"
            ],
            "mcpOAuth": ["server": ["accessToken": "mcp"]]
        ]

        let renewed = try XCTUnwrap(ClaudeLoginRenewal.renewed(saved, with: [
            "access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 28_800,
            "scope": "user:profile user:inference"
        ], now: now))

        let oauth = try XCTUnwrap(renewed["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 1_800_028_800_000)
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:profile", "user:inference"])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertEqual((renewed["mcpOAuth"] as? [String: Any])?.keys.sorted(), ["server"])
    }

    func testRenewedLoginKeepsRefreshTokenWhenNoNewOneComesBack() throws {
        let saved: [String: Any] = ["claudeAiOauth": ["accessToken": "a", "refreshToken": "keep", "expiresAt": 1]]
        let renewed = ClaudeLoginRenewal.renewed(saved, with: ["access_token": "b", "expires_in": 60], now: Date())
        XCTAssertEqual((renewed?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "keep")
        XCTAssertNil(ClaudeLoginRenewal.renewed(saved, with: ["error": "invalid_grant"], now: Date()))
    }

    func testRenewedLoginSavesWhenTheRefreshTokenEndsLikeClaudeCode() throws {
        let saved: [String: Any] = ["claudeAiOauth": ["accessToken": "a", "refreshToken": "r", "expiresAt": 1, "refreshTokenExpiresAt": 5]]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let extended = ClaudeLoginRenewal.renewed(saved, with: ["access_token": "b", "expires_in": 60, "refresh_token_expires_in": 2_592_000], now: now)
        XCTAssertEqual((extended?["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? Int, 1_802_592_000_000)

        // Claude Code keeps the saved date when the answer doesn't carry a new one.
        let kept = ClaudeLoginRenewal.renewed(saved, with: ["access_token": "b", "expires_in": 60], now: now)
        XCTAssertEqual((kept?["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? Int, 5)
    }

    func testCardWarnsInTheLastThreeDaysBeforeASignInEnds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = "Run claude and sign in again to keep it."

        XCTAssertNil(ClaudeLoginRenewal.endingNote(refreshTokenExpiresAt: now.addingTimeInterval(4 * 86_400), now: now, signInAgain: fix))
        XCTAssertEqual(ClaudeLoginRenewal.endingNote(refreshTokenExpiresAt: now.addingTimeInterval(2.5 * 86_400), now: now, signInAgain: fix),
                       "This sign-in ends in 3 days. Run claude and sign in again to keep it.")
        XCTAssertEqual(ClaudeLoginRenewal.endingNote(refreshTokenExpiresAt: now.addingTimeInterval(3_600), now: now, signInAgain: fix),
                       "This sign-in ends in 1 day. Run claude and sign in again to keep it.")
        XCTAssertNil(ClaudeLoginRenewal.endingNote(refreshTokenExpiresAt: nil, now: now, signInAgain: fix))
    }

    func testOnlyARejectedLoginSaysToSignInAgain() {
        XCTAssertEqual(
            LoginRenewal.failureMessage(status: 400, reason: "invalid_grant", signInAgain: "Remove this login and add it again."),
            "Sign-in expired and couldn't be renewed (invalid_grant). Remove this login and add it again."
        )
        XCTAssertEqual(
            LoginRenewal.failureMessage(status: 429, reason: "Rate limited. Please try again later.", signInAgain: "x"),
            "Couldn't renew this sign-in just now (HTTP 429: Rate limited. Please try again later.). Token Stats tries again in a few minutes."
        )
        XCTAssertEqual(
            LoginRenewal.failureMessage(status: 0, reason: "The Internet connection appears to be offline.", signInAgain: "x"),
            "Couldn't renew this sign-in just now (The Internet connection appears to be offline.). Token Stats tries again in a few minutes."
        )
    }

    func testEachLoginRenewsUnderTheFolderClaudeCodeLocks() {
        let home = URL(fileURLWithPath: "/Users/me")
        let added = URL(fileURLWithPath: "/Users/me/Library/Application Support/Token Stats/Accounts/claude-1")

        XCTAssertEqual(ClaudeLoginRenewal.configDir(service: "Claude Code-credentials-1a2b3c4d", folder: added, home: home, environment: [:]), added)
        XCTAssertEqual(ClaudeLoginRenewal.configDir(service: "Claude Code-credentials", folder: nil, home: home, environment: [:])?.path, "/Users/me/.claude")
        XCTAssertEqual(ClaudeLoginRenewal.configDir(service: "Claude Code-credentials", folder: nil, home: home,
                                                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/elsewhere"])?.path, "/tmp/elsewhere")
        // A login made with some other CLAUDE_CONFIG_DIR: its folder (and so its lock) is unknown, so it's left alone.
        XCTAssertNil(ClaudeLoginRenewal.configDir(service: "Claude Code-credentials-99999999", folder: nil, home: home, environment: [:]))
        XCTAssertEqual(ClaudeLoginRenewal.lockURL(configDir: added).lastPathComponent, ".oauth_refresh.lock")
    }

    func testKeychainAccountComesFromSecurityAttributes() {
        let output = """
        keychain: "/Users/me/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials-1a2b3c4d"
            "acct"<blob>="m5-mike"
            "svce"<blob>="Claude Code-credentials-1a2b3c4d"
        """
        XCTAssertEqual(ClaudeLoginRenewal.keychainAccount(fromAttributes: output), "m5-mike")
        XCTAssertNil(ClaudeLoginRenewal.keychainAccount(fromAttributes: "nothing here"))
    }

    func testSavedLoginIsPlainASCIIAndReadsBackTheSame() throws {
        let saved: [String: Any] = ["claudeAiOauth": ["accessToken": "a/b"], "mcpOAuth": ["Café 🚀": ["url": "https://x.dev/mcp"]]]

        let data = try ClaudeLoginRenewal.asciiJSON(saved)

        XCTAssertTrue(data.allSatisfy { $0 < 0x80 })
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#"Caf\u00e9 \ud83d\ude80"#))
        XCTAssertTrue(text.contains("https://x.dev/mcp"))
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((back["mcpOAuth"] as? [String: Any])?.keys.first, "Café 🚀")
        XCTAssertEqual((back["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "a/b")
    }

    func testSaveCommandHexEncodesTheLoginLikeClaudeCode() {
        let command = ClaudeLoginRenewal.saveCommand(account: "m5-mike", service: "Claude Code-credentials-1a2b3c4d", secret: Data("{}".utf8))
        XCTAssertEqual(command, #"add-generic-password -U -a "m5-mike" -s "Claude Code-credentials-1a2b3c4d" -X "7b7d""# + "\n")
    }
}
