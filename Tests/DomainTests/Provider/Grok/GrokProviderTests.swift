import Testing
import Foundation
import Mockable
@testable import Domain
@testable import Infrastructure

@Suite("GrokProvider Tests")
@MainActor
struct GrokProviderTests {

    // MARK: - Identity Tests

    @Test
    func `grok provider has correct id`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.id == "grok")
    }

    @Test
    func `grok provider has correct name`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.name == "Grok")
    }

    @Test
    func `grok provider has correct cliCommand`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.cliCommand == "grok")
    }

    @Test
    func `grok provider has dashboard URL pointing to grok com`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.dashboardURL != nil)
        #expect(grok.dashboardURL?.host?.contains("grok.com") == true)
    }

    @Test
    func `grok provider has status page URL pointing to x ai`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.statusPageURL != nil)
        #expect(grok.statusPageURL?.host?.contains("x.ai") == true)
    }

    @Test
    func `grok provider is enabled by default`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.isEnabled == true)
    }

    // MARK: - State Tests

    @Test
    func `grok provider starts with no snapshot`() {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(grok.snapshot == nil)
        #expect(grok.lastError == nil)
        #expect(grok.isSyncing == false)
    }

    @Test
    func `grok provider isAvailable delegates to probe`() async {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).isAvailable().willReturn(true)
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        #expect(await grok.isAvailable() == true)
    }

    // MARK: - Refresh Tests

    @Test
    func `refresh updates snapshot on success`() async throws {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        let expected = UsageSnapshot(
            providerId: "grok",
            quotas: [
                UsageQuota(percentRemaining: 4.0, quotaType: .weekly, providerId: "grok")
            ],
            capturedAt: Date()
        )
        given(mockProbe).probe().willReturn(expected)
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        let result = try await grok.refresh()

        #expect(result == expected)
        #expect(grok.snapshot == expected)
        #expect(grok.lastError == nil)
    }

    @Test
    func `refresh records error on failure`() async {
        let settings = MockRepositoryFactory.makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willThrow(ProbeError.authenticationRequired)
        let grok = GrokProvider(probe: mockProbe, settingsRepository: settings)

        await #expect(throws: ProbeError.authenticationRequired) {
            try await grok.refresh()
        }
        #expect(grok.snapshot == nil)
        #expect(grok.lastError as? ProbeError == .authenticationRequired)
    }

    @Test
    func `lists stored extra accounts beside the default`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        settings.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["grokHome": "/tmp/grok-work"]),
            forProvider: "grok"
        )
        let grok = GrokProvider(probe: MockUsageProbe(), settingsRepository: settings)

        #expect(grok.accounts.map(\.accountId) == ["default", "work"])
    }

    @Test
    func `switchAccount then refresh uses the selected grok account`() async throws {
        let settings = InMemoryMultiAccountSettingsRepository()
        settings.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["grokHome": "/tmp/grok-work"]),
            forProvider: "grok"
        )

        let defaultProbe = MockUsageProbe()
        let workProbe = MockUsageProbe()
        let defaultSnap = UsageSnapshot(
            providerId: "grok",
            quotas: [UsageQuota(percentRemaining: 90, quotaType: .weekly, providerId: "grok")],
            capturedAt: Date(),
            accountEmail: "home@example.com"
        )
        let workSnap = UsageSnapshot(
            providerId: "grok",
            quotas: [UsageQuota(percentRemaining: 20, quotaType: .weekly, providerId: "grok")],
            capturedAt: Date(),
            accountEmail: "work@example.com"
        )
        given(defaultProbe).probe().willReturn(defaultSnap)
        given(workProbe).probe().willReturn(workSnap)

        let grok = GrokProvider(
            probe: defaultProbe,
            settingsRepository: settings,
            probeFactory: { config in
                config.accountId == "work" ? workProbe : defaultProbe
            }
        )

        _ = try await grok.refresh()
        #expect(grok.snapshot?.accountEmail == "home@example.com")

        #expect(grok.switchAccount(to: "work") == true)
        _ = try await grok.refresh()
        #expect(grok.snapshot?.accountEmail == "work@example.com")
        #expect(settings.activeAccountId(forProvider: "grok") == "work")
    }

    @Test
    func `addSessionAccount persists extra grok home`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let grok = GrokProvider(probe: MockUsageProbe(), settingsRepository: settings)

        let accountId = grok.addSessionAccount(label: "Work", probeConfig: ["grokHome": "/tmp/grok-work"])

        #expect(accountId == "work")
        #expect(grok.accounts.map(\.label) == ["Default", "Work"])
        #expect(settings.accounts(forProvider: "grok")[0].probeConfig["grokHome"] == "/tmp/grok-work")
    }

    @Test
    func `accountConfig exposes stored probe config and an implicit default`() {
        let settings = InMemoryMultiAccountSettingsRepository()
        let grok = GrokProvider(probe: MockUsageProbe(), settingsRepository: settings)
        grok.addSessionAccount(label: "Work", probeConfig: ["grokHome": "/tmp/grok-work"])

        #expect(grok.accountConfig(for: "work")?.probeConfig["grokHome"] == "/tmp/grok-work")
        #expect(grok.accountConfig(for: ProviderAccount.defaultAccountId)?.probeConfig.isEmpty == true)
        #expect(grok.accountConfig(for: "missing") == nil)
    }
}
