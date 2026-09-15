import Foundation
@testable import Domain

/// In-memory `MultiAccountSettingsRepository` for provider tests.
final class InMemoryMultiAccountSettingsRepository: MultiAccountSettingsRepository, @unchecked Sendable {
    private var enabledByProvider: [String: Bool] = [:]
    private var accountsByProvider: [String: [ProviderAccountConfig]] = [:]
    private var activeAccountIds: [String: String] = [:]
    private var cardURLs: [String: String] = [:]

    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool {
        enabledByProvider[id] ?? defaultValue
    }

    func setEnabled(_ enabled: Bool, forProvider id: String) {
        enabledByProvider[id] = enabled
    }

    func customCardURL(forProvider id: String) -> String? {
        cardURLs[id]
    }

    func setCustomCardURL(_ url: String?, forProvider id: String) {
        if let url, !url.isEmpty {
            cardURLs[id] = url
        } else {
            cardURLs.removeValue(forKey: id)
        }
    }

    func accounts(forProvider id: String) -> [ProviderAccountConfig] {
        accountsByProvider[id] ?? []
    }

    func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        var list = accountsByProvider[id] ?? []
        list.removeAll { $0.accountId == config.accountId }
        list.append(config)
        accountsByProvider[id] = list
    }

    func removeAccount(accountId: String, forProvider id: String) {
        var list = accountsByProvider[id] ?? []
        list.removeAll { $0.accountId == accountId }
        accountsByProvider[id] = list
        if activeAccountIds[id] == accountId {
            activeAccountIds.removeValue(forKey: id)
        }
    }

    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        var list = accountsByProvider[id] ?? []
        if let index = list.firstIndex(where: { $0.accountId == config.accountId }) {
            list[index] = config
        } else {
            list.append(config)
        }
        accountsByProvider[id] = list
    }

    func activeAccountId(forProvider id: String) -> String? {
        activeAccountIds[id]
    }

    func setActiveAccountId(_ accountId: String?, forProvider id: String) {
        if let accountId {
            activeAccountIds[id] = accountId
        } else {
            activeAccountIds.removeValue(forKey: id)
        }
    }
}
