import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct DefaultCodexRPCClientTests {

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when CLI executor finds binary`() {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/codex")

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)

        #expect(client.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when CLI executor cannot find binary`() {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)

        #expect(client.isAvailable() == false)
    }

    // MARK: - fetchRateLimits Parsing Tests

    // Helper to create mock responses for the full RPC sequence
    private func setupMockTransport(_ mockTransport: MockRPCTransport, rateLimitsResponse: String) {
        var callCount = 0
        given(mockTransport).send(.any).willReturn(())
        given(mockTransport).receive().willProduce {
            callCount += 1
            if callCount == 1 {
                // Response to initialize request (id=1)
                return Data("{\"id\":1,\"result\":{}}".utf8)
            } else {
                // Response to rateLimits request (id=2)
                return Data(rateLimitsResponse.utf8)
            }
        }
        given(mockTransport).close().willReturn(())
    }

    @Test
    func `fetchRateLimits parses primary and secondary windows`() async throws {
        // Given
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":30,"resetsAt":1735000000},"secondary":{"usedPercent":50,"resetsAt":1735500000}}}}
        """)

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When
        let result = try await client.fetchRateLimits()

        // Then
        #expect(result.planType == "pro")
        #expect(result.primary?.usedPercent == 30)
        #expect(result.secondary?.usedPercent == 50)
    }

    @Test
    func `fetchRateLimits parses primary only when secondary is missing`() async throws {
        // Given
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"basic","primary":{"usedPercent":25}}}}
        """)

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When
        let result = try await client.fetchRateLimits()

        // Then
        #expect(result.primary?.usedPercent == 25)
        #expect(result.secondary == nil)
    }

    @Test
    func `fetchRateLimits returns free plan defaults when no limits`() async throws {
        // Given
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"free"}}}
        """)

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When
        let result = try await client.fetchRateLimits()

        // Then
        #expect(result.planType == "free")
        #expect(result.primary?.usedPercent == 0)
        #expect(result.primary?.resetDescription == "Free plan")
    }

    @Test
    func `fetchRateLimits throws when no rate limits and TTY fallback fails`() async throws {
        // Given - paid plan but no rate limits data, TTY fallback also fails
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"pro"}}}
        """)
        // TTY fallback will also fail
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.self) {
            try await client.fetchRateLimits()
        }
    }

    @Test
    func `fetchRateLimits throws on RPC error and TTY fallback fails`() async throws {
        // Given - RPC returns error, TTY fallback also fails
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"error":{"message":"Authentication required"}}
        """)
        // TTY fallback will also fail
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.self) {
            try await client.fetchRateLimits()
        }
    }

    @Test
    func `fetchRateLimits throws when result missing and TTY fallback fails`() async throws {
        // Given - response without result, TTY fallback also fails
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2}
        """)
        // TTY fallback will also fail
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)

        // When & Then
        await #expect(throws: ProbeError.self) {
            try await client.fetchRateLimits()
        }
    }

    @Test
    func `fetchRateLimits parses individualLimit remainingPercent`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"enterprise","primary":{"usedPercent":30},"secondary":{"usedPercent":50},"individualLimit":{"limit":"25000","used":"8000","remainingPercent":68,"resetsAt":1778137680}}}}
        """)

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)
        let result = try await client.fetchRateLimits()

        #expect(result.planType == "enterprise")
        #expect(result.primary?.usedPercent == 30)
        #expect(result.secondary?.usedPercent == 50)
        #expect(result.individualLimit?.remainingPercent == 68)
        #expect(result.individualLimit?.used == 8_000)
        #expect(result.individualLimit?.limit == 25_000)
        #expect(result.individualLimit?.resetsAt == Date(timeIntervalSince1970: 1_778_137_680))
    }

    @Test
    func `fetchRateLimits parses fractional individualLimit used and limit`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"business","individualLimit":{"limit":"6000","used":"5186.841861009598","remainingPercent":14,"resetsAt":1788220800}}}}
        """)
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)
        let result = try await client.fetchRateLimits()

        #expect(result.individualLimit?.remainingPercent == 14)
        #expect(result.individualLimit?.used == 5_186.841861009598)
        #expect(result.individualLimit?.limit == 6_000)
    }

    @Test
    func `fetchRateLimits succeeds with only individualLimit`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"enterprise","individualLimit":{"limit":"25000","used":"8000","remainingPercent":68,"resetsAt":1778137680}}}}
        """)
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)
        let result = try await client.fetchRateLimits()

        #expect(result.individualLimit?.remainingPercent == 68)
        #expect(result.primary == nil)
        #expect(result.secondary == nil)
    }

    @Test
    func `fetchRateLimits computes remainingPercent from used and limit when missing`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"enterprise","individualLimit":{"limit":"25000","used":"8000","resetsAt":1778137680}}}}
        """)
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any).willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(transport: mockTransport, cliExecutor: mockExecutor)
        let result = try await client.fetchRateLimits()

        #expect(result.individualLimit?.remainingPercent == 68)
    }

    @Test
    func `TTY fallback parses monthly credit limit`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        given(mockTransport).send(.any).willReturn(())
        given(mockTransport).receive().willThrow(ProbeError.executionFailed("RPC failed"))
        given(mockTransport).close().willReturn(())

        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willReturn(CLIResult(output: """
            Monthly Credit Limit
            ████████████████░░░░ 68% remaining
            8,000 of 25,000 credits used
            """, exitCode: 0))

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.transportFactory = { _, _ in mockTransport }

        let result = try await client.fetchRateLimits()
        #expect(result.individualLimit?.remainingPercent == 68)
    }

    // MARK: - parseWindow Tests

    @Test
    func `parseWindow extracts usedPercent and resetDescription`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let window: [String: Any] = [
            "usedPercent": 45.5,
            "resetsAt": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        ]

        let result = client.parseWindow(window)

        #expect(result?.usedPercent == 45.5)
        #expect(result?.resetDescription?.contains("Resets in") == true)
    }

    @Test
    func `parseWindow returns nil for non-dict value`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        #expect(client.parseWindow("invalid") == nil)
        #expect(client.parseWindow(nil) == nil)
        #expect(client.parseWindow(123) == nil)
    }

    @Test
    func `parseWindow returns nil when usedPercent missing`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let window: [String: Any] = ["resetsAt": 1735000000]

        #expect(client.parseWindow(window) == nil)
    }

    // MARK: - formatResetTime Tests

    @Test
    func `formatResetTime shows hours and minutes`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let futureDate = Date().addingTimeInterval(2 * 3600 + 30 * 60) // 2h 30m
        let result = client.formatResetTime(futureDate)

        #expect(result.contains("2h"))
        #expect(result.contains("30m") || result.contains("29m")) // allow for timing
    }

    @Test
    func `formatResetTime shows days, hours and minutes`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let futureDate = Date().addingTimeInterval(2 * 86400 + 3 * 3600 + 30 * 60) // 2d 3h 30m
        let result = client.formatResetTime(futureDate)

        #expect(result.contains("Resets in"))
        #expect(result.contains("2d"))
        #expect(result.contains("3h"))
    }

    @Test
    func `formatResetTime shows only minutes when less than an hour`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let futureDate = Date().addingTimeInterval(45 * 60) // 45m
        let result = client.formatResetTime(futureDate)

        #expect(result.contains("Resets in"))
        #expect(result.contains("m"))
        #expect(!result.contains("h"))
    }

    @Test
    func `formatResetTime shows soon for past dates`() {
        let mockTransport = MockRPCTransport()
        let client = DefaultCodexRPCClient(transport: mockTransport)

        let pastDate = Date().addingTimeInterval(-60) // 1 minute ago
        let result = client.formatResetTime(pastDate)

        #expect(result == "Resets soon")
    }

    // MARK: - shutdown Tests

    @Test
    func `shutdown closes transport`() {
        let mockTransport = MockRPCTransport()
        given(mockTransport).close().willReturn(())

        let client = DefaultCodexRPCClient(transport: mockTransport)
        client.shutdown()

        verify(mockTransport).close().called(.atLeastOnce)
    }

    // MARK: - Process Leak Fix Tests

    @Test
    func `fetchRateLimits closes locally created transport after successful fetch`() async throws {
        // Given - production path: no injected transport, factory provides a mock
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":30,"resetsAt":1735000000}}}}
        """)

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.transportFactory = { _, _ in mockTransport }

        // When - fetch succeeds, shutdown is NOT called (simulates if caller forgets)
        _ = try await client.fetchRateLimits()

        // Then - transport must be closed even without shutdown(), preventing process leak
        verify(mockTransport).close().called(.atLeastOnce)
    }

    @Test
    func `fetchRateLimits closes locally created transport even when RPC throws`() async throws {
        // Given - RPC will fail, TTY fallback will also fail
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        given(mockTransport).send(.any).willReturn(())
        given(mockTransport).receive().willThrow(ProbeError.executionFailed("RPC failed"))
        given(mockTransport).close().willReturn(())
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willThrow(ProbeError.executionFailed("TTY not available"))

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.transportFactory = { _, _ in mockTransport }

        // When - fetch throws
        await #expect(throws: ProbeError.self) {
            try await client.fetchRateLimits()
        }

        // Then - transport must still be closed despite the error
        verify(mockTransport).close().called(.atLeastOnce)
    }

    // MARK: - CLI Argument Compatibility (#259)

    /// Codex removed `untrusted` from `--ask-for-approval` (only `on-request`
    /// and `never` remain), so passing it makes the CLI exit at argument
    /// parsing — killing the RPC path *and* the TTY fallback at once.
    @Test
    func `spawns app-server with an approval policy the Codex CLI still accepts`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        setupMockTransport(mockTransport, rateLimitsResponse: """
        {"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":30,"resetsAt":1735000000}}}}
        """)

        var spawnedArgs: [String] = []
        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.transportFactory = { _, args in
            spawnedArgs = args
            return mockTransport
        }

        _ = try await client.fetchRateLimits()

        let approval = approvalPolicy(in: spawnedArgs)
        #expect(approval == "never")
        #expect(!spawnedArgs.contains("untrusted"))
        #expect(spawnedArgs.contains("app-server"))
    }

    @Test
    func `TTY fallback uses an approval policy the Codex CLI still accepts`() async throws {
        let mockTransport = MockRPCTransport()
        let mockExecutor = MockCLIExecutor()
        given(mockTransport).send(.any).willReturn(())
        given(mockTransport).receive().willThrow(ProbeError.executionFailed("RPC failed"))
        given(mockTransport).close().willReturn(())

        var ttyArgs: [String] = []
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willProduce { _, args, _, _, _, _ in
                ttyArgs = args
                return CLIResult(output: "5h limit\n[####------] 40% left", exitCode: 0)
            }

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.transportFactory = { _, _ in mockTransport }

        _ = try await client.fetchRateLimits()

        #expect(approvalPolicy(in: ttyArgs) == "never")
        #expect(!ttyArgs.contains("untrusted"))
    }

    @Test
    func `fetchRateLimits falls back to TTY when RPC receive hangs past timeout`() async throws {
        let hangingTransport = HangingRPCTransport()
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willReturn(CLIResult(output: """
            Monthly Credit Limit
            ████████████████░░░░ 68% remaining
            8,000 of 25,000 credits used
            """, exitCode: 0))

        let client = DefaultCodexRPCClient(executable: "codex", cliExecutor: mockExecutor)
        client.rpcTimeout = 0.3
        client.transportFactory = { _, _ in hangingTransport }

        let started = ContinuousClock.now
        let result = try await client.fetchRateLimits()
        let elapsed = ContinuousClock.now - started

        #expect(result.individualLimit?.remainingPercent == 68)
        #expect(elapsed < .seconds(2))
        #expect(hangingTransport.closeCount >= 1)
    }

    /// Value passed to `-a` / `--ask-for-approval`, if any.
    private func approvalPolicy(in args: [String]) -> String? {
        guard let flagIndex = args.firstIndex(where: { $0 == "-a" || $0 == "--ask-for-approval" }),
              args.indices.contains(flagIndex + 1) else {
            return nil
        }
        return args[flagIndex + 1]
    }
}

/// Stands in for `codex app-server` when it accepts the connection but never
/// writes a JSON-RPC reply. `close()` must resume `receive()` or the probe
/// stays stuck on yesterday's snapshot.
private final class HangingRPCTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var closeCount = 0

    func send(_ data: Data) throws {}

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if closed {
                continuation.resume(throwing: ProbeError.executionFailed("transport closed"))
                return
            }
            self.continuation = continuation
        }
    }

    func close() {
        lock.lock()
        closeCount += 1
        closed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: ProbeError.executionFailed("transport closed"))
    }
}
