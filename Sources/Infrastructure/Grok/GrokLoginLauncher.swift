import Foundation
import Domain

/// Signs a Grok account in through the official CLI, isolated in its own
/// `GROK_HOME`.
///
/// The CLI keeps exactly one active login per `GROK_HOME`, so MyMeter gives each
/// extra account a dedicated folder under `~/.mymeter/grok/<account>` and runs
/// `GROK_HOME=<folder> grok login` in Terminal. Once `auth.json` shows up in
/// that folder the account is ready; the CLI (or MyMeter) refreshes it from then on.
public struct GrokLoginLauncher: Sendable {
    public enum LaunchError: LocalizedError, Sendable {
        case timedOut
        case scriptWriteFailed(String)
        case terminalLaunchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Sign-in did not complete in time. Finish `grok login` in Terminal and try again."
            case .scriptWriteFailed(let reason):
                return "Could not prepare the sign-in script: \(reason)"
            case .terminalLaunchFailed(let reason):
                return "Could not open Terminal: \(reason)"
            }
        }
    }

    /// `~/.mymeter/grok` — where MyMeter-managed `GROK_HOME` folders live.
    public static var defaultAccountsRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".mymeter/grok")
    }

    /// Default time to wait for the user to finish the browser sign-in.
    public static let defaultTimeout: TimeInterval = 5 * 60

    private let accountsRoot: String
    private let scriptsDirectory: String
    private let locateGrok: @Sendable () -> String?
    private let openInTerminal: @Sendable (URL) throws -> Void

    public init(
        accountsRoot: String = GrokLoginLauncher.defaultAccountsRoot,
        scriptsDirectory: String = FileManager.default.temporaryDirectory.path,
        locateGrok: @escaping @Sendable () -> String? = { BinaryLocator().locate("grok") },
        openInTerminal: @escaping @Sendable (URL) throws -> Void = GrokLoginLauncher.openWithTerminal
    ) {
        self.accountsRoot = accountsRoot
        self.scriptsDirectory = scriptsDirectory
        self.locateGrok = locateGrok
        self.openInTerminal = openInTerminal
    }

    /// The dedicated `GROK_HOME` for a MyMeter-managed account.
    public func homeDirectory(named name: String) -> String {
        (accountsRoot as NSString).appendingPathComponent(name)
    }

    /// Creates `grokHome` if needed, then opens a Terminal window running
    /// `GROK_HOME=<grokHome> grok login`. Returns the script that was launched.
    @discardableResult
    public func launchLogin(grokHome: String, label: String) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: grokHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(atPath: scriptsDirectory, withIntermediateDirectories: true)
        } catch {
            throw LaunchError.scriptWriteFailed(error.localizedDescription)
        }

        let script = Self.loginScript(
            grokHome: grokHome,
            grokBinary: locateGrok() ?? "grok",
            label: label
        )
        let scriptURL = URL(fileURLWithPath: scriptsDirectory)
            .appendingPathComponent("mymeter-grok-login-\(UUID().uuidString).command")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw LaunchError.scriptWriteFailed(error.localizedDescription)
        }

        AppLog.credentials.info("Grok: launching CLI sign-in for account '\(label)'")
        do {
            try openInTerminal(scriptURL)
        } catch {
            throw LaunchError.terminalLaunchFailed(error.localizedDescription)
        }
        return scriptURL
    }

    /// Polls `grokHome/auth.json` until it holds a usable credential written at
    /// or after `since`. Returns `nil` on timeout or cancellation.
    public func waitForCredentials(
        grokHome: String,
        since: Date,
        timeout: TimeInterval = GrokLoginLauncher.defaultTimeout,
        pollInterval: Duration = .milliseconds(1500)
    ) async -> GrokCredentialResult? {
        let loader = GrokCredentialLoader(grokHome: grokHome)
        let deadline = Date().addingTimeInterval(timeout)
        // Allow a little clock slop between our `since` and the file system timestamp.
        let earliestAccepted = since.addingTimeInterval(-2)

        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let modified = Self.modificationDate(of: loader.authFilePath),
               modified >= earliestAccepted,
               let credentials = loader.loadCredentials() {
                AppLog.credentials.info("Grok: CLI sign-in completed, auth file detected")
                return credentials
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return nil
            }
        }
        AppLog.credentials.warning("Grok: CLI sign-in timed out waiting for auth file")
        return nil
    }

    // MARK: - Script

    /// The zsh script Terminal runs. Pure so it can be unit-tested.
    static func loginScript(grokHome: String, grokBinary: String, label: String) -> String {
        let quotedHome = shellQuote(grokHome)
        let quotedBinary = shellQuote(grokBinary)
        let quotedLabel = shellQuote(label)
        return """
        #!/bin/zsh
        # Generated by MyMeter — signs in to Grok Build for one account in its own GROK_HOME.
        export GROK_HOME=\(quotedHome)
        echo "MyMeter · Grok sign-in for account: "\(quotedLabel)
        echo "GROK_HOME=$GROK_HOME"
        echo ""
        if \(quotedBinary) login; then
          echo ""
          echo "Signed in. You can close this window and return to MyMeter."
        else
          echo ""
          echo "grok login failed. Fix the problem above, then try again from MyMeter."
          read -k 1 -s "?Press any key to close..."
        fi

        """
    }

    /// Wraps `value` in single quotes, escaping embedded single quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Helpers

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Opens a `.command` script in Terminal via `/usr/bin/open`.
    @Sendable
    public static func openWithTerminal(_ scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LaunchError.terminalLaunchFailed("open exited with status \(process.terminationStatus)")
        }
    }
}
