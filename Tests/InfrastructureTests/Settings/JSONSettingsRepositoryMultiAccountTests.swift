import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("JSONSettingsRepository Multi-Account Settings Tests")
struct JSONSettingsRepositoryMultiAccountTests {

    private func makeRepository() -> (JSONSettingsRepository, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mymeter-multi-account-\(UUID().uuidString)")
        let fileURL = tempDir.appendingPathComponent("settings.json")
        let store = JSONSettingsStore(fileURL: fileURL)
        let repo = JSONSettingsRepository(store: store)
        return (repo, tempDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test
    func `accounts defaults to empty`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.accounts(forProvider: "cursor").isEmpty)
    }

    @Test
    func `addAccount persists and round-trips probeConfig`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            email: "work@example.com",
            probeConfig: ["userDataDir": "~/CursorWork"]
        )
        repo.addAccount(config, forProvider: "cursor")

        let loaded = repo.accounts(forProvider: "cursor")
        #expect(loaded == [config])
    }

    @Test
    func `accounts are isolated per provider`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.addAccount(
            ProviderAccountConfig(accountId: "work", label: "Work"),
            forProvider: "cursor"
        )
        repo.addAccount(
            ProviderAccountConfig(accountId: "home", label: "Home", probeConfig: ["grokHome": "/tmp/grok-home"]),
            forProvider: "grok"
        )

        #expect(repo.accounts(forProvider: "cursor").map(\.accountId) == ["work"])
        #expect(repo.accounts(forProvider: "grok").map(\.accountId) == ["home"])
    }

    @Test
    func `removeAccount deletes by account id`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.addAccount(ProviderAccountConfig(accountId: "work", label: "Work"), forProvider: "cursor")
        repo.addAccount(ProviderAccountConfig(accountId: "personal", label: "Personal"), forProvider: "cursor")
        repo.removeAccount(accountId: "work", forProvider: "cursor")

        #expect(repo.accounts(forProvider: "cursor").map(\.accountId) == ["personal"])
    }

    @Test
    func `activeAccountId persists independently`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        #expect(repo.activeAccountId(forProvider: "cursor") == nil)

        repo.setActiveAccountId("work", forProvider: "cursor")
        #expect(repo.activeAccountId(forProvider: "cursor") == "work")

        repo.setActiveAccountId(nil, forProvider: "cursor")
        #expect(repo.activeAccountId(forProvider: "cursor") == nil)
    }

    @Test
    func `updateAccount replaces matching account`() {
        let (repo, dir) = makeRepository()
        defer { cleanup(dir) }

        repo.addAccount(ProviderAccountConfig(accountId: "work", label: "Work"), forProvider: "cursor")
        repo.updateAccount(
            ProviderAccountConfig(accountId: "work", label: "Office", probeConfig: ["dbPath": "/tmp/state.vscdb"]),
            forProvider: "cursor"
        )

        let loaded = repo.accounts(forProvider: "cursor")
        #expect(loaded.count == 1)
        #expect(loaded[0].label == "Office")
        #expect(loaded[0].probeConfig["dbPath"] == "/tmp/state.vscdb")
    }
}
