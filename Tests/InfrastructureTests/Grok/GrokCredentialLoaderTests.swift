import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("GrokCredentialLoader Tests")
struct GrokCredentialLoaderTests {

    // MARK: - Test Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-credential-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Writes `auth.json` directly inside `directory`, mirroring the official
    /// layout where `GROK_HOME` (default `~/.grok`) holds `auth.json`.
    private func writeAuthFile(at directory: URL, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: directory.appendingPathComponent("auth.json"))
    }

    private func oidcEntry(
        key: String = "test-access-token",
        refreshToken: String? = "test-refresh-token",
        email: String? = "user@example.com",
        expiresAt: String? = "2099-01-01T00:00:00.000000Z"
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "key": key,
            "auth_mode": "oidc",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-123"
        ]
        if let refreshToken { entry["refresh_token"] = refreshToken }
        if let email { entry["email"] = email }
        if let expiresAt { entry["expires_at"] = expiresAt }
        return entry
    }

    // MARK: - Path Tests

    @Test
    func `default auth file lives at dot grok slash auth json`() {
        let loader = GrokCredentialLoader()

        #expect(loader.authFilePath == NSHomeDirectory() + "/.grok/auth.json")
    }

    @Test
    func `auth file lives directly inside a custom GROK_HOME`() {
        let loader = GrokCredentialLoader(grokHome: "/tmp/grok-work")

        #expect(loader.authFilePath == "/tmp/grok-work/auth.json")
    }

    @Test
    func `explicit auth file path wins over GROK_HOME`() {
        let loader = GrokCredentialLoader(grokHome: "/tmp/grok-work", authFilePath: "/tmp/other/auth.json")

        #expect(loader.authFilePath == "/tmp/other/auth.json")
    }

    @Test
    func `cliGrokHome is the GROK_HOME folder by default`() {
        #expect(GrokCredentialLoader(grokHome: "/tmp/grok-work").cliGrokHome == "/tmp/grok-work")
    }

    @Test
    func `cliGrokHome derives from an explicit auth json path`() {
        let loader = GrokCredentialLoader(grokHome: "/tmp/grok-work", authFilePath: "/tmp/other/auth.json")

        #expect(loader.cliGrokHome == "/tmp/other")
    }

    @Test
    func `cliGrokHome is nil for a non standard auth file name`() {
        let loader = GrokCredentialLoader(authFilePath: "/tmp/other/custom-auth.json")

        #expect(loader.cliGrokHome == nil)
    }

    // MARK: - Loading Tests

    @Test
    func `loads credentials from oidc entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": oidcEntry()
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        let credentials = loader.loadCredentials()

        #expect(credentials != nil)
        #expect(credentials?.accessToken == "test-access-token")
        #expect(credentials?.refreshToken == "test-refresh-token")
        #expect(credentials?.email == "user@example.com")
        #expect(credentials?.oidcIssuer == "https://auth.x.ai")
        #expect(credentials?.oidcClientId == "client-123")
        #expect(credentials?.entryKey == "https://auth.x.ai::client-123")
    }

    @Test
    func `returns nil when auth file missing`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = GrokCredentialLoader(grokHome: tempDir.path)

        #expect(loader.loadCredentials() == nil)
    }

    @Test
    func `returns nil when no entry has a token`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": ["key": "", "auth_mode": "oidc"]
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)

        #expect(loader.loadCredentials() == nil)
    }

    @Test
    func `prefers refreshable entry over api key entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://accounts.x.ai/sign-in": ["key": "legacy-api-key"],
            "https://auth.x.ai::client-123": oidcEntry(key: "oidc-token")
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        let credentials = loader.loadCredentials()

        #expect(credentials?.accessToken == "oidc-token")
    }

    @Test
    func `treats empty refresh token as absent`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var entry = oidcEntry()
        entry["refresh_token"] = ""
        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": entry
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        let credentials = try #require(loader.loadCredentials())

        #expect(credentials.refreshToken == nil)
    }

    // MARK: - Expiry Tests

    @Test
    func `needsRefresh true when token expired`() {
        let loader = GrokCredentialLoader()

        #expect(loader.needsRefresh(expiresAt: "2020-01-01T00:00:00.000000Z") == true)
    }

    @Test
    func `needsRefresh false when token valid`() {
        let loader = GrokCredentialLoader()

        #expect(loader.needsRefresh(expiresAt: "2099-01-01T00:00:00.000000Z") == false)
    }

    @Test
    func `needsRefresh false when no expiry recorded`() {
        let loader = GrokCredentialLoader()

        #expect(loader.needsRefresh(expiresAt: nil) == false)
    }

    // MARK: - Date Parsing Tests

    @Test
    func `parses microsecond fraction timestamps`() {
        let date = GrokCredentialLoader.parseDate("2026-07-26T21:03:09.138930Z")

        #expect(date != nil)
    }

    @Test
    func `parses timestamps with utc offset`() {
        let date = GrokCredentialLoader.parseDate("2026-07-23T05:09:24.881042+00:00")

        #expect(date != nil)
    }

    @Test
    func `parses timestamps without fraction`() {
        let date = GrokCredentialLoader.parseDate("2026-07-23T05:09:24Z")

        #expect(date != nil)
    }

    @Test
    func `returns nil for garbage timestamps`() {
        #expect(GrokCredentialLoader.parseDate("not a date") == nil)
        #expect(GrokCredentialLoader.parseDate(nil) == nil)
    }

    // MARK: - Save Tests

    @Test
    func `saveCredentials updates token fields and preserves the rest`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": oidcEntry()
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        var credentials = try #require(loader.loadCredentials())

        credentials.accessToken = "new-token"
        credentials.refreshToken = "new-refresh-token"
        credentials.expiresAt = "2099-06-01T00:00:00.000Z"
        loader.saveCredentials(credentials)

        let reloaded = try #require(loader.loadCredentials())
        #expect(reloaded.accessToken == "new-token")
        #expect(reloaded.refreshToken == "new-refresh-token")
        #expect(reloaded.expiresAt == "2099-06-01T00:00:00.000Z")
        // Fields the refresh doesn't touch stay intact
        #expect(reloaded.email == "user@example.com")
        #expect(reloaded.oidcIssuer == "https://auth.x.ai")
    }

    @Test
    func `loadAllCredentials returns every usable entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://accounts.x.ai/sign-in": ["key": "legacy-api-key"],
            "https://auth.x.ai::client-123": oidcEntry(key: "oidc-token", email: "oidc@example.com")
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        let all = loader.loadAllCredentials()

        #expect(all.count == 2)
        #expect(all.map(\.email).contains("oidc@example.com"))
    }

    @Test
    func `loadCredentials prefers requested entry key`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://accounts.x.ai/sign-in": ["key": "legacy-api-key", "email": "legacy@example.com"],
            "https://auth.x.ai::client-123": oidcEntry(key: "oidc-token", email: "oidc@example.com")
        ])

        let loader = GrokCredentialLoader(grokHome: tempDir.path)
        let selected = loader.loadCredentials(entryKey: "https://accounts.x.ai/sign-in")

        #expect(selected?.accessToken == "legacy-api-key")
        #expect(selected?.email == "legacy@example.com")
    }

    @Test
    func `loadCredentials from an explicit auth file path`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authURL = tempDir.appendingPathComponent("custom-auth.json")
        let json: [String: Any] = [
            "https://auth.x.ai::client-123": oidcEntry(email: "custom@example.com")
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: authURL)

        let loader = GrokCredentialLoader(
            grokHome: "/does-not-exist",
            authFilePath: authURL.path
        )

        #expect(loader.loadCredentials()?.email == "custom@example.com")
    }
}
