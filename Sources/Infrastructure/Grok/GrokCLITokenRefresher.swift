import Foundation

/// Lets the official `grok` CLI refresh an account's OAuth token.
///
/// The CLI refreshes near-expiry tokens itself whenever it talks to the API,
/// serialising the write under its own `auth.json.lock`. Running a cheap,
/// headless `GROK_HOME=<home> grok models` therefore rotates the token without
/// MyMeter ever writing `auth.json` — no lock contention, no duplicate refresh
/// grants. Callers re-read the file afterwards and fall back to the in-app
/// refresh when the CLI is missing or did not rotate the token.
public struct GrokCLITokenRefresher: Sendable {
    /// Runs `binary` against `grokHome` and reports whether it exited cleanly.
    public typealias Runner = @Sendable (_ binary: String, _ grokHome: String, _ timeout: TimeInterval) async -> Bool

    /// `grok models` normally returns in a second or two; leave room for a
    /// token refresh round-trip and a possible update check.
    public static let defaultTimeout: TimeInterval = 20

    private let locateGrok: @Sendable () -> String?
    private let timeout: TimeInterval
    private let run: Runner

    public init(
        locateGrok: @escaping @Sendable () -> String? = { BinaryLocator().locate("grok") },
        timeout: TimeInterval = GrokCLITokenRefresher.defaultTimeout,
        run: Runner? = nil
    ) {
        self.locateGrok = locateGrok
        self.timeout = timeout
        self.run = run ?? { binary, grokHome, timeout in
            await Self.runHeadless(binary: binary, grokHome: grokHome, timeout: timeout)
        }
    }

    /// Asks the CLI to touch the API (and thereby refresh the token) for `grokHome`.
    /// Returns `false` when the CLI is not installed or the run failed.
    public func refresh(grokHome: String) async -> Bool {
        guard let binary = locateGrok() else {
            AppLog.probes.debug("Grok: CLI not found, skipping CLI-delegated refresh")
            return false
        }
        return await run(binary, grokHome, timeout)
    }

    // MARK: - Headless execution

    /// Runs `binary models` with `GROK_HOME` set, no TTY and no stdin, killing it
    /// if it outlives `timeout` (e.g. because it tried to prompt for a login).
    static func runHeadless(
        binary: String,
        grokHome: String,
        arguments: [String] = ["models"],
        timeout: TimeInterval
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GROK_HOME"] = grokHome
        environment["NO_COLOR"] = "1"
        process.environment = environment

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            process.terminationHandler = { finished in
                let succeeded = finished.terminationReason == .exit && finished.terminationStatus == 0
                if resumed.claim() {
                    continuation.resume(returning: succeeded)
                }
            }

            do {
                try process.run()
            } catch {
                AppLog.probes.warning("Grok: could not launch CLI for refresh: \(error.localizedDescription)")
                if resumed.claim() {
                    continuation.resume(returning: false)
                }
                return
            }

            let watchdog = DispatchQueue.global(qos: .utility)
            watchdog.asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                AppLog.probes.warning("Grok: CLI refresh exceeded \(Int(timeout))s, terminating")
                process.terminate()
                watchdog.asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
}

/// Guards a continuation against being resumed twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
