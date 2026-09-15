import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct CodexUsageProbeTests {

    @Test
    func `isAvailable returns true when client finds binary`() async {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).isAvailable().willReturn(true)
        let probe = CodexUsageProbe(client: mockClient)

        // When & Then
        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when client cannot find binary`() async {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).isAvailable().willReturn(false)
        let probe = CodexUsageProbe(client: mockClient)

        // When & Then
        #expect(await probe.isAvailable() == false)
    }

    @Test
    func `stripANSICodes removes colors`() {
        let input = "\u{1B}[32mGreen\u{1B}[0m Text"
        #expect(CodexUsageProbe.stripANSICodes(input) == "Green Text")
    }

    @Test
    func `extractUsageError finds common errors`() {
        #expect(CodexUsageProbe.extractUsageError("data not available yet") != nil)
        #expect(CodexUsageProbe.extractUsageError("Update available: 1.2.1 ... codex") == .updateRequired)
        #expect(CodexUsageProbe.extractUsageError("All good") == nil)
    }
}

// MARK: - Probe Tests

@Suite
struct CodexUsageProbeRPCTests {

    @Test
    func `probe returns snapshot from client`() async throws {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 30, resetDescription: "Resets in 2h"),
                secondary: CodexRateLimitWindow(usedPercent: 50, resetDescription: "Resets in 3d"),
                planType: "pro"
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)

        // When
        let snapshot = try await probe.probe()

        // Then
        #expect(snapshot.providerId == "codex")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.sessionQuota?.percentRemaining == 70) // 100 - 30
        #expect(snapshot.weeklyQuota?.percentRemaining == 50) // 100 - 50
    }

    @Test
    func `probe returns only primary quota when secondary is nil`() async throws {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 25, resetDescription: nil),
                secondary: nil
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)

        // When
        let snapshot = try await probe.probe()

        // Then
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.sessionQuota?.percentRemaining == 75)
        #expect(snapshot.weeklyQuota == nil)
    }

    @Test
    func `probe handles free plan with zero usage`() async throws {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 0, resetDescription: "Free plan"),
                secondary: nil,
                planType: "free"
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)

        // When
        let snapshot = try await probe.probe()

        // Then
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.sessionQuota?.percentRemaining == 100)
    }

    @Test
    func `probe clamps negative percent remaining to zero`() async throws {
        // Given - usage over 100%
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 110, resetDescription: nil),
                secondary: nil
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)

        // When
        let snapshot = try await probe.probe()

        // Then
        #expect(snapshot.sessionQuota?.percentRemaining == 0) // max(0, 100-110)
    }

    @Test
    func `probe shuts down client after fetch`() async throws {
        // Given
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 50, resetDescription: nil),
                secondary: nil
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)

        // When
        _ = try await probe.probe()

        // Then - verify shutdown was called
        verify(mockClient).shutdown().called(.atLeastOnce)
    }

    @Test
    func `probe maps individualLimit to monthly quota`() async throws {
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: CodexRateLimitWindow(usedPercent: 20, resetDescription: nil),
                secondary: nil,
                individualLimit: CodexIndividualLimit(remainingPercent: 68)
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)
        let snapshot = try await probe.probe()

        #expect(snapshot.quota(for: .timeLimit("Monthly"))?.percentRemaining == 68)
        #expect(snapshot.sessionQuota?.percentRemaining == 80)
    }

    @Test
    func `probe returns monthly-only snapshot for enterprise credit accounts`() async throws {
        let mockClient = MockCodexRPCClient()
        given(mockClient).fetchRateLimits().willReturn(
            CodexRateLimitsResponse(
                primary: nil,
                secondary: nil,
                planType: "enterprise",
                individualLimit: CodexIndividualLimit(remainingPercent: 42)
            )
        )
        given(mockClient).shutdown().willReturn(())

        let probe = CodexUsageProbe(client: mockClient)
        let snapshot = try await probe.probe()

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quota(for: .timeLimit("Monthly"))?.percentRemaining == 42)
    }
}

// MARK: - Mapping Tests

@Suite
struct CodexRateLimitsToSnapshotMappingTests {

    @Test
    func `maps primary window to session quota`() throws {
        let response = CodexRateLimitsResponse(
            primary: CodexRateLimitWindow(usedPercent: 40, resetDescription: "Resets in 1h"),
            secondary: nil
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.sessionQuota?.percentRemaining == 60)
        #expect(snapshot.sessionQuota?.resetText == "Resets in 1h")
    }

    @Test
    func `maps secondary window to weekly quota`() throws {
        let response = CodexRateLimitsResponse(
            primary: nil,
            secondary: CodexRateLimitWindow(usedPercent: 20, resetDescription: "Resets in 5d")
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.weeklyQuota?.percentRemaining == 80)
        #expect(snapshot.weeklyQuota?.resetText == "Resets in 5d")
    }

    @Test
    func `maps both windows to quotas`() throws {
        let response = CodexRateLimitsResponse(
            primary: CodexRateLimitWindow(usedPercent: 30, resetDescription: nil),
            secondary: CodexRateLimitWindow(usedPercent: 60, resetDescription: nil)
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.sessionQuota?.percentRemaining == 70)
        #expect(snapshot.weeklyQuota?.percentRemaining == 40)
    }

    @Test
    func `throws when no rate limits found`() throws {
        let response = CodexRateLimitsResponse(primary: nil, secondary: nil)

        #expect(throws: ProbeError.self) {
            try CodexUsageProbe.mapRateLimitsToSnapshot(response)
        }
    }

    @Test
    func `sets provider id to codex`() throws {
        let response = CodexRateLimitsResponse(
            primary: CodexRateLimitWindow(usedPercent: 0, resetDescription: nil),
            secondary: nil
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.providerId == "codex")
    }

    @Test
    func `maps individualLimit to monthly quota`() throws {
        let resetsAt = Date(timeIntervalSince1970: 1_778_137_680)
        let response = CodexRateLimitsResponse(
            primary: nil,
            secondary: nil,
            individualLimit: CodexIndividualLimit(
                remainingPercent: 68,
                resetDescription: "Resets in 1d",
                resetsAt: resetsAt,
                used: 8_000,
                limit: 25_000
            )
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)
        let monthly = snapshot.quota(for: .timeLimit("Monthly"))

        #expect(snapshot.quotas.count == 1)
        #expect(monthly?.percentRemaining == 68)
        #expect(monthly?.resetText == "8,000 / 25,000 credits")
        #expect(monthly?.usageCaption == "8,000 / 25,000 credits")
        #expect(monthly?.resetsAt == resetsAt)
        #expect(monthly?.providerId == "codex")
    }

    @Test
    func `maps fractional individualLimit used and limit onto monthly caption`() throws {
        let response = CodexRateLimitsResponse(
            primary: nil,
            secondary: nil,
            individualLimit: CodexIndividualLimit(
                remainingPercent: 14,
                used: 5_186.841861009598,
                limit: 6_000
            )
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)
        let monthly = snapshot.quota(for: .timeLimit("Monthly"))

        #expect(monthly?.percentRemaining == 14)
        #expect(monthly?.resetText == "5,187 / 6,000 credits")
        #expect(monthly?.usageCaption == "5,187 / 6,000 credits")
    }

    @Test
    func `maps individualLimit alongside session and weekly quotas`() throws {
        let response = CodexRateLimitsResponse(
            primary: CodexRateLimitWindow(usedPercent: 30, resetDescription: nil),
            secondary: CodexRateLimitWindow(usedPercent: 60, resetDescription: nil),
            individualLimit: CodexIndividualLimit(remainingPercent: 68)
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.quotas.count == 3)
        #expect(snapshot.sessionQuota?.percentRemaining == 70)
        #expect(snapshot.weeklyQuota?.percentRemaining == 40)
        #expect(snapshot.quota(for: .timeLimit("Monthly"))?.percentRemaining == 68)
    }

    @Test
    func `does not map monthly quota when individualLimit is absent`() throws {
        let response = CodexRateLimitsResponse(
            primary: CodexRateLimitWindow(usedPercent: 10, resetDescription: nil),
            secondary: nil
        )

        let snapshot = try CodexUsageProbe.mapRateLimitsToSnapshot(response)

        #expect(snapshot.quota(for: .timeLimit("Monthly")) == nil)
        #expect(snapshot.quotas.count == 1)
    }
}
