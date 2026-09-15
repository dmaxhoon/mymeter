import Foundation
import Domain

/// Default implementation of CodexRPCClient that communicates with `codex app-server`.
/// Uses RPCTransport for communication, enabling testability.
public final class DefaultCodexRPCClient: CodexRPCClient, @unchecked Sendable {
    private let executable: String
    private let cliExecutor: CLIExecutor
    private let transport: RPCTransport?
    private var nextID = 1

    /// Package-internal: allows tests to inject a mock transport for the production (no-injection) code path.
    var transportFactory: ((String, [String]) throws -> RPCTransport)?

    /// How long `codex app-server` may sit silent before we kill it and try TTY.
    /// A hung RPC leaves the last snapshot on screen indefinitely (no `lastError`).
    var rpcTimeout: TimeInterval = 20

    /// Default initializer - uses real CLI executor and creates transport lazily.
    public init(executable: String = "codex", cliExecutor: CLIExecutor? = nil) {
        self.executable = executable
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor()
        self.transport = nil
    }

    /// Internal initializer for testing with mock transport.
    init(transport: RPCTransport, cliExecutor: CLIExecutor? = nil) {
        self.executable = "codex"
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor()
        self.transport = transport
    }

    /// Arguments every Codex invocation gets, for both the app-server and the
    /// TTY fallback.
    ///
    /// `--ask-for-approval` must stay a value the CLI still knows: Codex dropped
    /// `untrusted` (leaving `on-request` and `never`), and an unknown value makes
    /// the CLI exit at argument parsing — which took out the RPC path *and* the
    /// TTY fallback at once (#259). `never` is accepted by old and new builds
    /// alike, and cannot stall a non-interactive pipe on an approval prompt.
    /// The read-only sandbox still keeps anything Codex might run boxed in.
    static let baseArguments = ["-s", "read-only", "-a", "never"]

    public func isAvailable() -> Bool {
        let binaryName = executable
        if cliExecutor.locate(binaryName) != nil {
            return true
        }
        
        // Log diagnostic info when binary not found
        let env = ProcessInfo.processInfo.environment
        AppLog.probes.error("Codex binary '\(binaryName)' not found in PATH")
        AppLog.probes.info("Current directory: \(FileManager.default.currentDirectoryPath)")
        AppLog.probes.info("PATH: \(env["PATH"] ?? "<not set>")")
        return false
    }

    public func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        // Try RPC first, fall back to TTY
        do {
            return try await fetchViaRPC()
        } catch {
            AppLog.probes.warning("Codex RPC failed: \(error.localizedDescription), trying TTY fallback...")
            return try await fetchViaTTY()
        }
    }

    // MARK: - RPC Approach

    private func fetchViaRPC() async throws -> CodexRateLimitsResponse {
        let activeTransport: RPCTransport
        let ownsTransport: Bool
        if let transport = self.transport {
            activeTransport = transport
            ownsTransport = false
        } else {
            let factory = transportFactory ?? { exec, args in
                try ProcessRPCTransport(executable: exec, arguments: args)
            }
            activeTransport = try factory(executable, Self.baseArguments + ["app-server"])
            ownsTransport = true
        }
        defer {
            if ownsTransport {
                activeTransport.close()
            }
        }

        return try await withThrowingTaskGroup(of: CodexRateLimitsResponse.self) { group in
            group.addTask {
                try await self.performRPC(transport: activeTransport)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(self.rpcTimeout))
                throw ProbeError.timeout
            }

            do {
                guard let result = try await group.next() else {
                    throw ProbeError.timeout
                }
                group.cancelAll()
                return result
            } catch {
                // Unblock `receive()` waiting on a silent app-server before TTY fallback.
                activeTransport.close()
                group.cancelAll()
                throw error
            }
        }
    }

    private func performRPC(transport activeTransport: RPCTransport) async throws -> CodexRateLimitsResponse {
        // Initialize RPC connection
        _ = try await request(transport: activeTransport, method: "initialize", params: [
            "clientInfo": ["name": "mymeter", "version": "1.0.0"]
        ])
        try sendNotification(transport: activeTransport, method: "initialized")

        // Fetch rate limits
        let message = try await request(transport: activeTransport, method: "account/rateLimits/read")

        // Log raw response
        if let data = try? JSONSerialization.data(withJSONObject: message, options: .prettyPrinted),
           let jsonString = String(data: data, encoding: .utf8) {
            AppLog.probes.debug("Codex RPC raw response:\n\(jsonString)")
        }

        guard let result = message["result"] as? [String: Any] else {
            AppLog.probes.error("No result in response: \(String(describing: message))")
            throw ProbeError.parseFailed("Invalid rate limits response")
        }

        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            AppLog.probes.error("No rateLimits in result: \(String(describing: result))")
            throw ProbeError.parseFailed("No rateLimits in response")
        }

        let planType = rateLimits["planType"] as? String
        AppLog.probes.info("Codex plan type: \(planType ?? "unknown")")

        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])
        let individualLimit = parseIndividualLimit(rateLimits["individualLimit"])

        // If plan is free and no limits, create default "unlimited" quotas
        if primary == nil && secondary == nil && individualLimit == nil {
            if planType == "free" {
                AppLog.probes.info("Codex free plan - returning unlimited quotas")
                return CodexRateLimitsResponse(
                    primary: CodexRateLimitWindow(usedPercent: 0, resetDescription: "Free plan"),
                    secondary: nil,
                    planType: planType
                )
            }
            // No rate limit data available yet
            throw ProbeError.parseFailed("No rate limits available yet - make some API calls first")
        }

        return CodexRateLimitsResponse(
            primary: primary,
            secondary: secondary,
            planType: planType,
            individualLimit: individualLimit
        )
    }

    // MARK: - TTY Fallback

    private func fetchViaTTY() async throws -> CodexRateLimitsResponse {
        AppLog.probes.info("Starting Codex TTY fallback...")

        let result = try await cliExecutor.execute(
            binary: executable,
            args: Self.baseArguments,
            input: "/status\n",
            timeout: 20.0,
            workingDirectory: nil,
            autoResponses: [:]
        )

        AppLog.probes.debug("Codex TTY raw output:\n\(result.output)")

        do {
            return try parseTTYOutput(result.output)
        } catch {
            AppLog.probes.debug("Working directory: \(FileManager.default.currentDirectoryPath)")
            throw error
        }
    }

    private func parseTTYOutput(_ text: String) throws -> CodexRateLimitsResponse {
        let snapshot = try CodexUsageProbe.parse(text)

        let primary = snapshot.sessionQuota.map {
            CodexRateLimitWindow(usedPercent: 100 - $0.percentRemaining, resetDescription: $0.resetText)
        }
        let secondary = snapshot.weeklyQuota.map {
            CodexRateLimitWindow(usedPercent: 100 - $0.percentRemaining, resetDescription: $0.resetText)
        }
        let individualLimit = snapshot.quota(for: .timeLimit("Monthly")).map {
            CodexIndividualLimit(
                remainingPercent: $0.percentRemaining,
                resetDescription: $0.resetText,
                resetsAt: $0.resetsAt
            )
        }

        return CodexRateLimitsResponse(
            primary: primary,
            secondary: secondary,
            individualLimit: individualLimit
        )
    }

    // MARK: - Parsing Helpers

    internal func parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
        guard let dict = value as? [String: Any] else {
            AppLog.probes.debug("parseWindow: value is not a dict: \(String(describing: value))")
            return nil
        }

        AppLog.probes.debug("parseWindow dict keys: \(dict.keys.joined(separator: ", "))")

        guard let usedPercent = dict["usedPercent"] as? Double else {
            AppLog.probes.debug("parseWindow: no usedPercent in dict")
            return nil
        }

        var resetDescription: String?
        if let resetsAt = dict["resetsAt"] as? Int {
            let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
            resetDescription = formatResetTime(date)
        }

        return CodexRateLimitWindow(usedPercent: usedPercent, resetDescription: resetDescription)
    }

    internal func parseIndividualLimit(_ value: Any?) -> CodexIndividualLimit? {
        guard let dict = value as? [String: Any] else { return nil }

        let used = jsonNumber(dict["used"])
        let limit = jsonNumber(dict["limit"])

        let remainingPercent: Double?
        if let remaining = jsonNumber(dict["remainingPercent"]) ?? jsonNumber(dict["remaining_percent"]) {
            remainingPercent = remaining
        } else if let usedPercent = jsonNumber(dict["usedPercent"]) ?? jsonNumber(dict["used_percent"]) {
            remainingPercent = max(0, 100 - usedPercent)
        } else if let used, let limit, limit > 0 {
            remainingPercent = ((limit - used) / limit) * 100
        } else {
            remainingPercent = nil
        }

        guard let remainingPercent else { return nil }

        let resetsAt = jsonDate(dict["resetsAt"]) ?? jsonDate(dict["reset_at"])
        let resetDescription = resetsAt.map { formatResetTime($0) }

        return CodexIndividualLimit(
            remainingPercent: remainingPercent,
            resetDescription: resetDescription,
            resetsAt: resetsAt,
            used: used,
            limit: limit
        )
    }

    private func jsonNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let cleaned = string.replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        default:
            return nil
        }
    }

    private func jsonDate(_ value: Any?) -> Date? {
        guard let interval = jsonNumber(value) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    internal func formatResetTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }

        let days = Int(interval / 86400)
        let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if days > 0 {
            return "Resets in \(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    public func shutdown() {
        transport?.close()
    }

    // MARK: - JSON-RPC

    private func request(transport: RPCTransport, method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        try sendRequest(transport: transport, id: id, method: method, params: params)

        while true {
            let message = try await readNextMessage(transport: transport)

            // Skip notifications
            if message["id"] == nil {
                continue
            }

            guard let messageID = message["id"] as? Int, messageID == id else {
                continue
            }

            if let error = message["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                throw ProbeError.executionFailed("RPC error: \(errorMessage)")
            }

            return message
        }
    }

    private func sendNotification(transport: RPCTransport, method: String) throws {
        let payload: [String: Any] = ["method": method, "params": [:]]
        try sendPayload(transport: transport, payload: payload)
    }

    private func sendRequest(transport: RPCTransport, id: Int, method: String, params: [String: Any]?) throws {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params ?? [:]
        ]
        try sendPayload(transport: transport, payload: payload)
    }

    private func sendPayload(transport: RPCTransport, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try transport.send(data)
    }

    private func readNextMessage(transport: RPCTransport) async throws -> [String: Any] {
        while true {
            let data = try await transport.receive()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return json
        }
    }
}
