import XCTest
@testable import TokenStatsApp

final class LoginLockAndGrokTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDirectoryLockWaitsForAHolderAndTakesOverAStaleOne() async throws {
        let url = directory.appendingPathComponent(".oauth_refresh.lock")

        let held = try await DirectoryLock.acquire(url, timeout: 1)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        do {
            _ = try await DirectoryLock.acquire(url, timeout: 0.3)
            XCTFail("a held lock was acquired twice")
        } catch {}
        held.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A lock left by a process that died is stale after a minute, the same rule Claude Code uses.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: url.path)
        let taken = try await DirectoryLock.acquire(url, timeout: 0.3)
        taken.release()
    }

    func testGrokRequestIsAFormEncodedRefreshGrant() throws {
        let request = GrokLoginRenewal.request(
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!,
            refreshToken: "abc+/=", clientID: "client-1"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=refresh_token&refresh_token=abc%2B%2F%3D&client_id=client-1")
    }

    func testGrokRenewedLoginSwapsTokensAndKeepsTheRest() throws {
        let login: [String: Any] = [
            "key": "old", "refresh_token": "old-refresh", "expires_at": "2026-10-18T15:13:45.883441Z",
            "email": "me@example.com", "auth_mode": "oidc", "coding_data_retention_opt_out": true
        ]

        let renewed = try XCTUnwrap(GrokLoginRenewal.renewed(login, with: [
            "access_token": "new", "refresh_token": "new-refresh", "expires_in": 3600, "token_type": "Bearer"
        ], now: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertEqual(renewed["key"] as? String, "new")
        XCTAssertEqual(renewed["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(renewed["expires_at"] as? String, "2027-01-15T09:00:00.000Z")
        XCTAssertEqual(renewed["email"] as? String, "me@example.com")
        XCTAssertEqual(renewed["coding_data_retention_opt_out"] as? Bool, true)
        XCTAssertNil(GrokLoginRenewal.renewed(login, with: ["error": "invalid_grant"], now: Date()))
    }

    func testGrokLockRecordsHolderTheWayGrokDoes() {
        XCTAssertEqual(GrokLoginRenewal.lockContents(pid: 84273, now: Date(timeIntervalSince1970: 1_792_314_826.7)), "84273:1792314826")
    }
}
