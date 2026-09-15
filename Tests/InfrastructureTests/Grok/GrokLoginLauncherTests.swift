import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("GrokLoginLauncher Tests")
struct GrokLoginLauncherTests {

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-login-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeAuthFile(in grokHome: URL, email: String = "work@example.com") throws {
        let json: [String: Any] = [
            "https://auth.x.ai::client-123": [
                "key": "access-token",
                "auth_mode": "oidc",
                "email": email,
                "refresh_token": "refresh",
                "expires_at": "2099-01-01T00:00:00.000000Z",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "client-123"
            ]
        ]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: grokHome.appendingPathComponent("auth.json"))
    }

    // MARK: - Home directories

    @Test
    func `managed homes live under mymeter grok root`() {
        let launcher = GrokLoginLauncher(accountsRoot: "/tmp/mymeter/grok")

        #expect(launcher.homeDirectory(named: "work") == "/tmp/mymeter/grok/work")
    }

    @Test
    func `default accounts root is under the mymeter folder`() {
        #expect(GrokLoginLauncher.defaultAccountsRoot == NSHomeDirectory() + "/.mymeter/grok")
    }

    // MARK: - Script

    @Test
    func `login script exports GROK_HOME and runs grok login`() {
        let script = GrokLoginLauncher.loginScript(
            grokHome: "/Users/alice/.mymeter/grok/work",
            grokBinary: "/Users/alice/.grok/bin/grok",
            label: "Work"
        )

        #expect(script.hasPrefix("#!/bin/zsh"))
        #expect(script.contains("export GROK_HOME='/Users/alice/.mymeter/grok/work'"))
        #expect(script.contains("'/Users/alice/.grok/bin/grok' login"))
        #expect(script.contains("Work"))
    }

    @Test
    func `login script single-quotes paths with spaces and quotes`() {
        let script = GrokLoginLauncher.loginScript(
            grokHome: "/Users/al ice/it's/grok",
            grokBinary: "grok",
            label: "Al's Work"
        )

        #expect(script.contains("export GROK_HOME='/Users/al ice/it'\\''s/grok'"))
        #expect(script.contains("'grok' login"))
    }

    // MARK: - Launch

    @Test
    func `launchLogin creates the home, writes an executable script and opens it`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let opened = OpenedScripts()
        let launcher = GrokLoginLauncher(
            accountsRoot: tempDir.appendingPathComponent("root").path,
            scriptsDirectory: tempDir.appendingPathComponent("scripts").path,
            locateGrok: { "/opt/grok" },
            openInTerminal: { url in opened.append(url) }
        )

        let home = launcher.homeDirectory(named: "work")
        let scriptURL = try launcher.launchLogin(grokHome: home, label: "Work")

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(permissions & 0o100 != 0, "script must be executable by the owner")
        #expect(scriptURL.pathExtension == "command")

        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(contents.contains("export GROK_HOME='\(home)'"))
        #expect(contents.contains("'/opt/grok' login"))
        #expect(opened.urls == [scriptURL])
    }

    @Test
    func `launchLogin falls back to a bare grok command when the CLI is not located`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let launcher = GrokLoginLauncher(
            accountsRoot: tempDir.path,
            scriptsDirectory: tempDir.path,
            locateGrok: { nil },
            openInTerminal: { _ in }
        )

        let scriptURL = try launcher.launchLogin(grokHome: launcher.homeDirectory(named: "work"), label: "Work")
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(contents.contains("'grok' login"))
    }

    // MARK: - Waiting for credentials

    @Test
    func `waitForCredentials returns once a fresh auth file appears`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let launcher = GrokLoginLauncher(accountsRoot: tempDir.path, openInTerminal: { _ in })
        let home = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let started = Date()
        Task {
            try await Task.sleep(for: .milliseconds(150))
            try writeAuthFile(in: home)
        }

        let credentials = await launcher.waitForCredentials(
            grokHome: home.path,
            since: started,
            timeout: 5,
            pollInterval: .milliseconds(50)
        )

        #expect(credentials?.email == "work@example.com")
    }

    @Test
    func `waitForCredentials ignores an auth file older than the login start`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let launcher = GrokLoginLauncher(accountsRoot: tempDir.path, openInTerminal: { _ in })
        let home = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeAuthFile(in: home, email: "stale@example.com")

        // Pretend the login started well after the stale file was written.
        let started = Date().addingTimeInterval(60)

        let credentials = await launcher.waitForCredentials(
            grokHome: home.path,
            since: started,
            timeout: 0.3,
            pollInterval: .milliseconds(50)
        )

        #expect(credentials == nil)
    }

    @Test
    func `waitForCredentials returns nil on timeout`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let launcher = GrokLoginLauncher(accountsRoot: tempDir.path, openInTerminal: { _ in })

        let credentials = await launcher.waitForCredentials(
            grokHome: tempDir.appendingPathComponent("never").path,
            since: Date(),
            timeout: 0.2,
            pollInterval: .milliseconds(50)
        )

        #expect(credentials == nil)
    }
}

/// Thread-safe recorder for URLs handed to the Terminal opener.
private final class OpenedScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.withLock { storage }
    }

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }
}
