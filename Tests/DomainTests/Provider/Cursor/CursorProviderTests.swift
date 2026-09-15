import Foundation
import Mockable
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("CursorProvider Tests")
@MainActor
struct CursorProviderTests {

    private func snapshot(email: String, remaining: Double = 80) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "cursor",
            quotas: [
                UsageQuota(percentRemaining: remaining, quotaType: .timeLimit("Monthly"), providerId: "cursor")
            ],
            capturedAt: Date(),
            accountEmail: email
        )
    }

    @Test
    func `implicit default account is present with no stored accounts`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let probe = MockUsageProbe()
        let cursor = CursorProvider(probe: probe, settingsRepository: settings)

        #expect(cursor.accounts.count == 1)
        #expect(cursor.activeAccount.accountId == ProviderAccount.defaultAccountId)
        #expect(cursor.accounts[0].isDefault)
    }

    @Test
    func `lists stored extra accounts beside the default`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        settings.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["dbPath": "/tmp/work.vscdb"]),
            forProvider: "cursor"
        )
        let probe = MockUsageProbe()
        let cursor = CursorProvider(probe: probe, settingsRepository: settings)

        #expect(cursor.accounts.map(\.accountId) == ["default", "work"])
        #expect(cursor.accounts[1].label == "Work")
    }

    @Test
    func `switchAccount persists active id and exposes cached snapshot`() async throws {
        let settings = InMemoryMultiAccountSettingsRepository()
        settings.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["dbPath": "/tmp/work.vscdb"]),
            forProvider: "cursor"
        )

        let defaultProbe = MockUsageProbe()
        let workProbe = MockUsageProbe()
        given(defaultProbe).probe().willReturn(snapshot(email: "home@example.com", remaining: 90))
        given(workProbe).probe().willReturn(snapshot(email: "work@example.com", remaining: 40))
        given(defaultProbe).isAvailable().willReturn(true)
        given(workProbe).isAvailable().willReturn(true)

        let cursor = CursorProvider(
            probe: defaultProbe,
            settingsRepository: settings,
            probeFactory: { config in
                config.accountId == "work" ? workProbe : defaultProbe
            }
        )

        _ = try await cursor.refresh()
        #expect(cursor.snapshot?.accountEmail == "home@example.com")

        #expect(cursor.switchAccount(to: "work") == true)
        #expect(settings.activeAccountId(forProvider: "cursor") == "work")
        #expect(cursor.activeAccount.accountId == "work")
        #expect(cursor.snapshot == nil)

        _ = try await cursor.refresh()
        #expect(cursor.snapshot?.accountEmail == "work@example.com")
        #expect(cursor.accountSnapshots["work"]?.accountEmail == "work@example.com")
    }

    @Test
    func `switchAccount returns false for unknown account`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let cursor = CursorProvider(probe: MockUsageProbe(), settingsRepository: settings)

        #expect(cursor.switchAccount(to: "missing") == false)
        #expect(cursor.activeAccount.accountId == ProviderAccount.defaultAccountId)
    }

    @Test
    func `addSessionAccount persists extra account`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let cursor = CursorProvider(probe: MockUsageProbe(), settingsRepository: settings)

        cursor.addSessionAccount(label: "Work", probeConfig: ["userDataDir": "/tmp/CursorWork"])

        #expect(cursor.accounts.map(\.label) == ["Default", "Work"])
        #expect(settings.accounts(forProvider: "cursor").map(\.accountId) == ["work"])
        #expect(settings.accounts(forProvider: "cursor")[0].probeConfig["userDataDir"] == "/tmp/CursorWork")
    }

    @Test
    func `removeSessionAccount cannot remove default`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let cursor = CursorProvider(probe: MockUsageProbe(), settingsRepository: settings)

        #expect(cursor.removeSessionAccount(accountId: ProviderAccount.defaultAccountId) == false)
        #expect(cursor.accounts.count == 1)
    }

    @Test
    func `removeSessionAccount deletes extra account and reverts to default`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let cursor = CursorProvider(probe: MockUsageProbe(), settingsRepository: settings)
        cursor.addSessionAccount(label: "Work", probeConfig: ["dbPath": "/tmp/work.vscdb"])
        #expect(cursor.switchAccount(to: "work") == true)

        #expect(cursor.removeSessionAccount(accountId: "work") == true)
        #expect(cursor.accounts.map(\.accountId) == ["default"])
        #expect(cursor.activeAccount.accountId == ProviderAccount.defaultAccountId)
        #expect(settings.accounts(forProvider: "cursor").isEmpty)
    }

    @Test
    func `refresh uses probe for the active account path`() async throws {
        let settings = InMemoryMultiAccountSettingsRepository()
        settings.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["dbPath": "/tmp/work.vscdb"]),
            forProvider: "cursor"
        )
        settings.setActiveAccountId("work", forProvider: "cursor")

        let defaultProbe = MockUsageProbe()
        let workProbe = MockUsageProbe()
        given(workProbe).probe().willReturn(snapshot(email: "work@example.com"))

        let cursor = CursorProvider(
            probe: defaultProbe,
            settingsRepository: settings,
            probeFactory: { config in
                config.accountId == "work" ? workProbe : defaultProbe
            }
        )

        #expect(cursor.activeAccount.accountId == "work")
        let result = try await cursor.refresh()
        #expect(result.accountEmail == "work@example.com")
    }
}
