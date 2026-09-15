import Foundation
import Mockable
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("CursorUsageProbe Tests")
struct CursorUsageProbeTests {

    private static let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyX2FiYzEyMyIsImlhdCI6MTIzNDU2Nzg5MH0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    private static let usageJSON = """
    {
        "membershipType": "pro",
        "isUnlimited": false,
        "individualUsage": {
            "plan": { "enabled": true, "used": 10, "limit": 500, "remaining": 490 },
            "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
        }
    }
    """.data(using: .utf8)!

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func makeCursorDatabase(at directory: URL, token: String, email: String?) throws -> String {
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        var sql = """
        CREATE TABLE ItemTable (key TEXT NOT NULL PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');
        """
        if let email {
            sql += "INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', '\(email)');"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return dbPath
    }

    private func httpResponse(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    @Test
    func `probe includes cached email from the selected database`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = try makeCursorDatabase(
            at: tempDir,
            token: Self.jwt,
            email: "work@example.com"
        )

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn((Self.usageJSON, httpResponse(200)))

        let probe = CursorUsageProbe(networkClient: mockNetwork, dbPathOverride: dbPath)
        let snapshot = try await probe.probe()

        #expect(snapshot.accountEmail == "work@example.com")
        #expect(snapshot.providerId == "cursor")
    }

    @Test
    func `probe succeeds without cached email`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = try makeCursorDatabase(at: tempDir, token: Self.jwt, email: nil)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn((Self.usageJSON, httpResponse(200)))

        let probe = CursorUsageProbe(networkClient: mockNetwork, dbPathOverride: dbPath)
        let snapshot = try await probe.probe()

        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.quotas.isEmpty == false)
    }

    @Test
    func `isAvailable uses the overridden database path`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missing = CursorUsageProbe(dbPathOverride: tempDir.appendingPathComponent("missing.vscdb").path)
        #expect(await missing.isAvailable() == false)

        let dbPath = try makeCursorDatabase(at: tempDir, token: Self.jwt, email: nil)
        let present = CursorUsageProbe(dbPathOverride: dbPath)
        #expect(await present.isAvailable() == true)
    }
}
