import Foundation
import Observation

/// Grok Build (xAI) — monitors weekly credit usage and per-product limits
/// (Grok Build, Grok Imagine, Grok Voice) via the xAI billing API.
@MainActor
@Observable
public final class GrokProvider: AIProvider, MultiAccountProvider {
    public typealias AccountProbeFactory = @Sendable (ProviderAccountConfig) -> any UsageProbe

    // MARK: - Identity

    public let id: String = "grok"
    public let name: String = "Grok"
    public let cliCommand: String = "grok"

    public var dashboardURL: URL? {
        URL(string: "https://grok.com/?_s=usage")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.x.ai")
    }

    public var isEnabled: Bool {
        didSet {
            settingsRepository.setEnabled(isEnabled, forProvider: id)
        }
    }

    // MARK: - State

    public private(set) var isSyncing: Bool = false
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: Error?

    public private(set) var accounts: [ProviderAccount]
    public private(set) var activeAccount: ProviderAccount
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]

    // MARK: - Internal

    private let probe: any UsageProbe
    private let probeFactory: AccountProbeFactory?
    private let settingsRepository: any ProviderSettingsRepository
    private var multiAccountSettings: (any MultiAccountSettingsRepository)? {
        settingsRepository as? MultiAccountSettingsRepository
    }

    public init(
        probe: any UsageProbe,
        settingsRepository: any ProviderSettingsRepository,
        probeFactory: AccountProbeFactory? = nil
    ) {
        self.probe = probe
        self.probeFactory = probeFactory
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: "grok")
        let loaded = Self.loadAccounts(from: settingsRepository)
        self.accounts = loaded.accounts
        self.activeAccount = loaded.active
    }

    // MARK: - AIProvider

    public func isAvailable() async -> Bool {
        for config in accountConfigs {
            if await probeFor(config).isAvailable() {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let snapshot = try await refreshAccount(activeAccount.accountId)
            lastError = nil
            return snapshot
        } catch {
            lastError = error
            throw error
        }
    }

    // MARK: - MultiAccountProvider

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard let account = accounts.first(where: { $0.accountId == accountId }) else {
            return false
        }
        multiAccountSettings?.setActiveAccountId(accountId, forProvider: id)
        activeAccount = account
        snapshot = accountSnapshots[accountId]
        lastError = nil
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        guard let config = accountConfigs.first(where: { $0.accountId == accountId }) else {
            throw ProbeError.executionFailed("Unknown Grok account: \(accountId)")
        }
        let newSnapshot = try await probeFor(config).probe()
        applySnapshot(newSnapshot, to: accountId)
        return newSnapshot
    }

    public func refreshAllAccounts() async {
        isSyncing = true
        defer { isSyncing = false }
        for config in accountConfigs {
            do {
                let snapshot = try await probeFor(config).probe()
                applySnapshot(snapshot, to: config.accountId)
            } catch {
                if config.accountId == activeAccount.accountId {
                    lastError = error
                }
            }
        }
    }

    // MARK: - Account management

    /// Registers an extra local session and returns its account id
    /// (`nil` when no multi-account storage is available).
    @discardableResult
    public func addSessionAccount(label: String, probeConfig: [String: String]) -> String? {
        guard let multiAccountSettings else { return nil }
        let existingIds = accountConfigs.map(\.accountId)
        let accountId = SessionAccounts.uniqueAccountId(from: label, existing: existingIds)
        let config = ProviderAccountConfig(
            accountId: accountId,
            label: label,
            probeConfig: probeConfig
        )
        multiAccountSettings.addAccount(config, forProvider: id)
        reloadAccounts()
        return accountId
    }

    /// The stored probe config for an account, including the implicit default.
    public func accountConfig(for accountId: String) -> ProviderAccountConfig? {
        accountConfigs.first(where: { $0.accountId == accountId })
    }

    @discardableResult
    public func removeSessionAccount(accountId: String) -> Bool {
        guard accountId != ProviderAccount.defaultAccountId else { return false }
        guard accounts.contains(where: { $0.accountId == accountId }) else { return false }
        multiAccountSettings?.removeAccount(accountId: accountId, forProvider: id)
        accountSnapshots.removeValue(forKey: accountId)
        reloadAccounts()
        snapshot = accountSnapshots[activeAccount.accountId]
        return true
    }

    // MARK: - Private

    private var accountConfigs: [ProviderAccountConfig] {
        SessionAccounts.resolved(stored: multiAccountSettings?.accounts(forProvider: id) ?? [])
    }

    private func probeFor(_ config: ProviderAccountConfig) -> any UsageProbe {
        probeFactory?(config) ?? probe
    }

    private func reloadAccounts() {
        let loaded = Self.loadAccounts(from: settingsRepository)
        accounts = loaded.accounts
        activeAccount = loaded.active
    }

    private func applySnapshot(_ snapshot: UsageSnapshot, to accountId: String) {
        accountSnapshots[accountId] = snapshot
        if let index = accounts.firstIndex(where: { $0.accountId == accountId }) {
            let current = accounts[index]
            accounts[index] = ProviderAccount(
                accountId: current.accountId,
                providerId: current.providerId,
                label: current.label,
                email: snapshot.accountEmail ?? current.email,
                organization: snapshot.accountOrganization ?? current.organization
            )
            if activeAccount.accountId == accountId {
                activeAccount = accounts[index]
            }
        }
        if activeAccount.accountId == accountId {
            self.snapshot = snapshot
        }
    }

    private static func loadAccounts(
        from settingsRepository: any ProviderSettingsRepository
    ) -> (accounts: [ProviderAccount], active: ProviderAccount) {
        let stored = (settingsRepository as? MultiAccountSettingsRepository)?.accounts(forProvider: "grok") ?? []
        let configs = SessionAccounts.resolved(stored: stored)
        let accounts = configs.map { $0.toProviderAccount(providerId: "grok") }
        let wanted = (settingsRepository as? MultiAccountSettingsRepository)?.activeAccountId(forProvider: "grok")
            ?? ProviderAccount.defaultAccountId
        let active = accounts.first(where: { $0.accountId == wanted }) ?? accounts[0]
        return (accounts, active)
    }
}
