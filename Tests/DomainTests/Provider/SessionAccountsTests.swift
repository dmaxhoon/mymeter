import Foundation
import Testing
@testable import Domain

@Suite("SessionAccounts")
struct SessionAccountsTests {

    @Test
    func `resolved prepends implicit default when none is stored`() {
        let stored = [
            ProviderAccountConfig(accountId: "work", label: "Work")
        ]

        let resolved = SessionAccounts.resolved(stored: stored, defaultLabel: "Default")

        #expect(resolved.count == 2)
        #expect(resolved[0].accountId == ProviderAccount.defaultAccountId)
        #expect(resolved[0].label == "Default")
        #expect(resolved[1].accountId == "work")
    }

    @Test
    func `resolved keeps stored default first when present`() {
        let stored = [
            ProviderAccountConfig(accountId: "default", label: "Home", probeConfig: ["dbPath": "/tmp/home.vscdb"]),
            ProviderAccountConfig(accountId: "work", label: "Work")
        ]

        let resolved = SessionAccounts.resolved(stored: stored)

        #expect(resolved.count == 2)
        #expect(resolved[0].label == "Home")
        #expect(resolved[0].probeConfig["dbPath"] == "/tmp/home.vscdb")
    }

    @Test
    func `resolved returns only implicit default when nothing is stored`() {
        let resolved = SessionAccounts.resolved(stored: [])

        #expect(resolved.count == 1)
        #expect(resolved[0].accountId == ProviderAccount.defaultAccountId)
    }

    @Test
    func `uniqueAccountId slugifies the label`() {
        let id = SessionAccounts.uniqueAccountId(from: "Work Laptop", existing: [])
        #expect(id == "work-laptop")
    }

    @Test
    func `uniqueAccountId suffixes duplicates`() {
        let id = SessionAccounts.uniqueAccountId(from: "Work", existing: ["work", "work-2"])
        #expect(id == "work-3")
    }
}
