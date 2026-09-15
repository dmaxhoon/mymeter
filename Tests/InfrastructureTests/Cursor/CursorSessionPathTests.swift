import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("CursorSessionPath Tests")
struct CursorSessionPathTests {

    @Test
    func `uses explicit dbPath`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["dbPath": "~/CursorWork/state.vscdb"]
        )

        let path = CursorSessionPath.databasePath(for: config)
        #expect(path.hasSuffix("/CursorWork/state.vscdb"))
        #expect(path.contains("~") == false)
    }

    @Test
    func `resolves userDataDir to state vscdb`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["userDataDir": "/tmp/CursorWork"]
        )

        #expect(
            CursorSessionPath.databasePath(for: config)
                == "/tmp/CursorWork/User/globalStorage/state.vscdb"
        )
    }

    @Test
    func `falls back to the default Cursor database`() {
        let config = ProviderAccountConfig(accountId: "default", label: "Default")
        #expect(CursorSessionPath.databasePath(for: config) == CursorUsageProbe.defaultDatabasePath)
    }

    @Test
    func `probeConfig treats vscdb files as dbPath`() {
        let config = CursorSessionPath.probeConfig(fromUserPath: "/tmp/state.vscdb")
        #expect(config["dbPath"] == "/tmp/state.vscdb")
    }

    @Test
    func `probeConfig treats folders as userDataDir`() {
        let config = CursorSessionPath.probeConfig(fromUserPath: "/tmp/CursorWork")
        #expect(config["userDataDir"] == "/tmp/CursorWork")
    }
}

@Suite("GrokSessionPath Tests")
struct GrokSessionPathTests {

    // MARK: - grokHome resolution (GROK_HOME semantics: the folder that holds auth.json)

    @Test
    func `uses grokHome when provided`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["grokHome": "/tmp/grok-work"]
        )

        #expect(GrokSessionPath.grokHome(for: config) == "/tmp/grok-work")
    }

    @Test
    func `expands tilde in grokHome`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["grokHome": "~/.grok-work"]
        )

        #expect(GrokSessionPath.grokHome(for: config) == NSHomeDirectory() + "/.grok-work")
    }

    @Test
    func `default grokHome is dot grok under the user home`() {
        let config = ProviderAccountConfig(accountId: "default", label: "Default")
        #expect(GrokSessionPath.grokHome(for: config) == NSHomeDirectory() + "/.grok")
        #expect(GrokSessionPath.authFilePath(for: config) == nil)
        #expect(GrokSessionPath.entryKey(for: config) == nil)
    }

    @Test
    func `returns authPath override`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["authPath": "~/custom/auth.json"]
        )

        let path = GrokSessionPath.authFilePath(for: config)
        #expect(path?.hasSuffix("/custom/auth.json") == true)
        #expect(path?.contains("~") == false)
    }

    @Test
    func `loginHome falls back to the auth file's folder`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["authPath": "/tmp/grok-work/auth.json"]
        )

        #expect(GrokSessionPath.loginHome(for: config) == "/tmp/grok-work")
    }

    @Test
    func `loginHome prefers grokHome over authPath`() {
        let config = ProviderAccountConfig(
            accountId: "work",
            label: "Work",
            probeConfig: ["grokHome": "/tmp/grok-work", "authPath": "/tmp/elsewhere/auth.json"]
        )

        #expect(GrokSessionPath.loginHome(for: config) == "/tmp/grok-work")
    }

    // MARK: - probeConfig(fromUserPath:)

    @Test
    func `probeConfig treats auth json as authPath`() {
        let config = GrokSessionPath.probeConfig(fromUserPath: "/tmp/custom/auth.json") { _ in false }
        #expect(config["authPath"] == "/tmp/custom/auth.json")
    }

    @Test
    func `probeConfig treats a folder holding auth json as GROK_HOME`() {
        let config = GrokSessionPath.probeConfig(fromUserPath: "/tmp/grok-work") { path in
            path == "/tmp/grok-work/auth.json"
        }
        #expect(config["grokHome"] == "/tmp/grok-work")
    }

    @Test
    func `probeConfig maps a user home containing dot grok to that dot grok folder`() {
        let config = GrokSessionPath.probeConfig(fromUserPath: "/Users/alice") { path in
            path == "/Users/alice/.grok/auth.json"
        }
        #expect(config["grokHome"] == "/Users/alice/.grok")
    }

    @Test
    func `probeConfig keeps a dot grok folder as GROK_HOME even before login`() {
        let config = GrokSessionPath.probeConfig(fromUserPath: "/tmp/work/.grok") { _ in false }
        #expect(config["grokHome"] == "/tmp/work/.grok")
    }

    @Test
    func `probeConfig keeps an empty folder as GROK_HOME`() {
        let config = GrokSessionPath.probeConfig(fromUserPath: "~/.grok-work") { _ in false }
        #expect(config["grokHome"] == NSHomeDirectory() + "/.grok-work")
    }
}
