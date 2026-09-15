import SwiftUI
import Domain
import Infrastructure

struct CursorConfigCard: View {
    let monitor: QuotaMonitor

    private var cursorProvider: CursorProvider? {
        monitor.provider(for: "cursor") as? CursorProvider
    }

    var body: some View {
        if let cursor = cursorProvider {
            SessionAccountConfigCard(
                provider: cursor,
                title: "Accounts",
                subtitle: "Measure usage from additional Cursor data directories.",
                pathPlaceholder: "~/Library/Application Support/Cursor",
                pathHelp: "Add a Cursor --user-data-dir folder, or a state.vscdb file. The default local login is always included."
            ) { label, path in
                cursor.addSessionAccount(label: label, probeConfig: CursorSessionPath.probeConfig(fromUserPath: path))
            } onRemove: { accountId in
                _ = cursor.removeSessionAccount(accountId: accountId)
            }
        }
    }
}

struct GrokConfigCard: View {
    let monitor: QuotaMonitor

    private var grokProvider: GrokProvider? {
        monitor.provider(for: "grok") as? GrokProvider
    }

    var body: some View {
        if let grok = grokProvider {
            SessionAccountConfigCard(
                provider: grok,
                title: "Accounts",
                subtitle: "Track usage for more than one Grok Build account.",
                pathPlaceholder: "~/.grok-work",
                pathHelp: "Pick the GROK_HOME folder you signed in with (the folder that holds auth.json, e.g. ~/.grok-work) or an auth.json file. The default ~/.grok login is always included.",
                loginSupport: SessionLoginSupport(
                    buttonTitle: "Sign in with grok CLI",
                    help: "Opens Terminal and runs `grok login` in a folder dedicated to this account, so your default ~/.grok login stays untouched. Finish the sign-in in your browser and the account appears here automatically.",
                    waitingMessage: "Complete the sign-in in Terminal and your browser. This window closes on its own when the account is ready (up to 5 minutes).",
                    signIn: { label in
                        try await Self.signIn(label: label, provider: grok)
                    },
                    signInAgain: { account in
                        try await Self.signInAgain(account: account, provider: grok)
                    }
                )
            ) { label, path in
                grok.addSessionAccount(label: label, probeConfig: GrokSessionPath.probeConfig(fromUserPath: path))
            } onRemove: { accountId in
                _ = grok.removeSessionAccount(accountId: accountId)
            }
        }
    }

    // MARK: - CLI sign-in

    /// Signs a new account in to its own `~/.mymeter/grok/<id>` and registers it.
    @MainActor
    private static func signIn(label: String, provider grok: GrokProvider) async throws {
        let launcher = GrokLoginLauncher()
        let accountId = SessionAccounts.uniqueAccountId(from: label, existing: grok.accounts.map(\.accountId))
        let grokHome = launcher.homeDirectory(named: accountId)

        let started = Date()
        try launcher.launchLogin(grokHome: grokHome, label: label)
        guard await launcher.waitForCredentials(grokHome: grokHome, since: started) != nil else {
            throw GrokLoginLauncher.LaunchError.timedOut
        }
        try Task.checkCancellation()

        if let newId = grok.addSessionAccount(label: label, probeConfig: [GrokSessionPath.grokHomeKey: grokHome]) {
            _ = try? await grok.refreshAccount(newId)
        }
    }

    /// Re-runs `grok login` for an existing account in its own `GROK_HOME`.
    @MainActor
    private static func signInAgain(account: ProviderAccount, provider grok: GrokProvider) async throws {
        guard let config = grok.accountConfig(for: account.accountId) else { return }
        let launcher = GrokLoginLauncher()
        let grokHome = GrokSessionPath.loginHome(for: config)

        let started = Date()
        try launcher.launchLogin(grokHome: grokHome, label: account.displayName)
        guard await launcher.waitForCredentials(grokHome: grokHome, since: started) != nil else {
            throw GrokLoginLauncher.LaunchError.timedOut
        }
        _ = try? await grok.refreshAccount(account.accountId)
    }
}
