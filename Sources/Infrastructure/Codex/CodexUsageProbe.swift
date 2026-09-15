import Foundation
import Domain
import Mockable

// MARK: - Codex Service Protocol

/// Protocol for Codex service - from user's mental model: "Is it available?" and "Get my stats"
@Mockable
public protocol CodexRPCClient: Sendable {
    /// Is the Codex CLI available on this system?
    func isAvailable() -> Bool
    /// Fetch rate limits from Codex service
    func fetchRateLimits() async throws -> CodexRateLimitsResponse
    /// Cleanup resources
    func shutdown()
}

/// Response from Codex rate limits API.
public struct CodexRateLimitsResponse: Sendable, Equatable {
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let planType: String?
    /// Enterprise monthly credit cap from `rateLimits.individualLimit`.
    public let individualLimit: CodexIndividualLimit?

    public init(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        planType: String? = nil,
        individualLimit: CodexIndividualLimit? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.individualLimit = individualLimit
    }
}

/// Enterprise monthly credit limit from Codex `account/rateLimits/read`.
public struct CodexIndividualLimit: Sendable, Equatable {
    public let remainingPercent: Double
    public let resetDescription: String?
    public let resetsAt: Date?
    public let used: Double?
    public let limit: Double?

    public init(
        remainingPercent: Double,
        resetDescription: String? = nil,
        resetsAt: Date? = nil,
        used: Double? = nil,
        limit: Double? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.used = used
        self.limit = limit
    }

    /// Card caption for the monthly credit meter, e.g. "5,187 / 6,000 credits".
    public var usageCaption: String? {
        guard let used, let limit else { return nil }
        return Self.formattedUsage(used: used, limit: limit)
    }

    public static func formattedUsage(used: Double, limit: Double) -> String {
        "\(formatCreditNumber(used)) / \(formatCreditNumber(limit)) credits"
    }

    private static func formatCreditNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        let ceiled = ceil(value)
        return formatter.string(from: NSNumber(value: ceiled)) ?? "\(Int(ceiled))"
    }
}

/// A rate limit window from Codex API.
public struct CodexRateLimitWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let resetDescription: String?

    public init(usedPercent: Double, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.resetDescription = resetDescription
    }
}

/// Infrastructure adapter that probes the Codex CLI to fetch usage quotas.
public struct CodexUsageProbe: UsageProbe {
    private let client: CodexRPCClient

    public init(client: CodexRPCClient? = nil) {
        self.client = client ?? DefaultCodexRPCClient()
    }

    public func isAvailable() async -> Bool {
        client.isAvailable()
    }

    public func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting Codex probe...")
        defer { client.shutdown() }

        let limits = try await client.fetchRateLimits()
        let snapshot = try Self.mapRateLimitsToSnapshot(limits)

        AppLog.probes.info("Codex probe success: \(snapshot.quotas.count) quotas found")
        for quota in snapshot.quotas {
            let detail = quota.resetText.map { ", \($0)" } ?? ""
            AppLog.probes.info("  - \(quota.quotaType.displayName): \(Int(quota.percentRemaining))% remaining\(detail)")
        }
        return snapshot
    }

    /// Maps RPC rate limits response to a UsageSnapshot (internal for testing).
    internal static func mapRateLimitsToSnapshot(_ limits: CodexRateLimitsResponse) throws -> UsageSnapshot {
        var quotas: [UsageQuota] = []

        if let primary = limits.primary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - primary.usedPercent),
                quotaType: .session,
                providerId: "codex",
                resetText: primary.resetDescription
            ))
        }

        if let secondary = limits.secondary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - secondary.usedPercent),
                quotaType: .weekly,
                providerId: "codex",
                resetText: secondary.resetDescription
            ))
        }

        if let individual = limits.individualLimit {
            quotas.append(UsageQuota(
                percentRemaining: individual.remainingPercent,
                quotaType: .timeLimit("Monthly"),
                providerId: "codex",
                resetsAt: individual.resetsAt,
                resetText: individual.usageCaption ?? individual.resetDescription
            ))
        }

        guard !quotas.isEmpty else {
            AppLog.probes.error("Codex probe failed: no rate limits in RPC response")
            throw ProbeError.parseFailed("No rate limits found")
        }

        return UsageSnapshot(
            providerId: "codex",
            quotas: quotas,
            capturedAt: Date()
        )
    }

    // MARK: - Parsing (for TTY fallback)

    public static func parse(_ text: String) throws -> UsageSnapshot {
        let clean = stripANSICodes(text)

        if let error = extractUsageError(clean) {
            throw error
        }

        let fiveHourPct = extractPercent(labelSubstring: "5h limit", text: clean)
        let weeklyPct = extractPercent(labelSubstring: "Weekly limit", text: clean)
        let monthlyCredits = extractCreditUsage(labelSubstring: "monthly credit limit", text: clean)
        let monthlyPct = extractPercent(labelSubstring: "monthly credit limit", text: clean)
            ?? monthlyCredits.map { Int(((($0.limit - $0.used) / $0.limit) * 100).rounded()) }

        var quotas: [UsageQuota] = []

        if let fiveHourPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(fiveHourPct),
                quotaType: .session,
                providerId: "codex"
            ))
        }

        if let weeklyPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(weeklyPct),
                quotaType: .weekly,
                providerId: "codex"
            ))
        }

        if let monthlyPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(monthlyPct),
                quotaType: .timeLimit("Monthly"),
                providerId: "codex",
                resetText: monthlyCredits.map { CodexIndividualLimit.formattedUsage(used: $0.used, limit: $0.limit) }
            ))
        }

        if quotas.isEmpty {
            AppLog.probes.error("Codex parse failed: could not find usage limits in TTY output")
            AppLog.probes.debug("Raw output (original, \(text.count) chars): \(text.debugDescription)")
            AppLog.probes.debug("Raw output (cleaned, \(clean.count) chars): \(clean)")
            throw ProbeError.parseFailed("Could not find usage limits in Codex output")
        }

        return UsageSnapshot(
            providerId: "codex",
            quotas: quotas,
            capturedAt: Date()
        )
    }

    // MARK: - Text Parsing Helpers

    internal static func stripANSICodes(_ text: String) -> String {
        let pattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func extractPercent(labelSubstring: String, text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = percentFromLine(candidate) {
                    return pct
                }
            }
        }
        return nil
    }

    private struct CreditUsage {
        let used: Double
        let limit: Double
    }

    private static func extractCreditUsage(labelSubstring: String, text: String) -> CreditUsage? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()
        let pattern = #"([0-9,]+(?:\.[0-9]+)?)\s+of\s+([0-9,]+(?:\.[0-9]+)?)\s+credits\s+used"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let match = regex.firstMatch(in: candidate, options: [], range: range),
                      match.numberOfRanges >= 3,
                      let usedRange = Range(match.range(at: 1), in: candidate),
                      let limitRange = Range(match.range(at: 2), in: candidate) else {
                    continue
                }
                let usedText = candidate[usedRange].replacingOccurrences(of: ",", with: "")
                let limitText = candidate[limitRange].replacingOccurrences(of: ",", with: "")
                guard let used = Double(usedText), let limit = Double(limitText), limit > 0 else {
                    continue
                }
                return CreditUsage(used: used, limit: limit)
            }
        }
        return nil
    }

    private static func percentFromLine(_ line: String) -> Int? {
        let pattern = #"([0-9]{1,3})%\s+(?:left|remaining)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[valRange])
    }

    internal static func extractUsageError(_ text: String) -> ProbeError? {
        let lower = text.lowercased()

        if lower.contains("data not available yet") {
            AppLog.probes.error("Codex probe failed: data not available yet")
            return .parseFailed("Data not available yet")
        }

        if lower.contains("update available") && lower.contains("codex") {
            AppLog.probes.error("Codex probe failed: CLI update required")
            return .updateRequired
        }

        if lower.contains("not logged in") || lower.contains("please log in") {
            AppLog.probes.error("Codex probe failed: not logged in")
            return .authenticationRequired
        }

        return nil
    }
}

