import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("GrokCLITokenRefresher Tests")
struct GrokCLITokenRefresherTests {

    @Test
    func `refresh is skipped when the grok CLI is not installed`() async {
        let calls = CallRecorder()
        let refresher = GrokCLITokenRefresher(
            locateGrok: { nil },
            run: { _, _, _ in
                calls.record("run")
                return true
            }
        )

        let result = await refresher.refresh(grokHome: "/tmp/grok-work")

        #expect(result == false)
        #expect(calls.entries.isEmpty)
    }

    @Test
    func `refresh runs the located CLI against the account's GROK_HOME`() async {
        let calls = CallRecorder()
        let refresher = GrokCLITokenRefresher(
            locateGrok: { "/opt/grok" },
            timeout: 7,
            run: { binary, grokHome, timeout in
                calls.record("\(binary)|\(grokHome)|\(Int(timeout))")
                return true
            }
        )

        let result = await refresher.refresh(grokHome: "/tmp/grok-work")

        #expect(result == true)
        #expect(calls.entries == ["/opt/grok|/tmp/grok-work|7"])
    }

    @Test
    func `refresh reports a failed CLI run`() async {
        let refresher = GrokCLITokenRefresher(
            locateGrok: { "/opt/grok" },
            run: { _, _, _ in false }
        )

        #expect(await refresher.refresh(grokHome: "/tmp/grok-work") == false)
    }

    @Test
    func `headless run of a missing binary fails instead of hanging`() async {
        let result = await GrokCLITokenRefresher.runHeadless(
            binary: "/definitely/not/here/grok",
            grokHome: "/tmp/grok-work",
            timeout: 2
        )

        #expect(result == false)
    }

    @Test
    func `headless run kills a process that outlives the timeout`() async {
        let started = Date()
        let result = await GrokCLITokenRefresher.runHeadless(
            binary: "/bin/sleep",
            grokHome: "/tmp/grok-work",
            arguments: ["30"],
            timeout: 0.5
        )

        #expect(result == false)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test
    func `headless run passes GROK_HOME to the child and reports success`() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cli-refresher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let marker = tempDir.appendingPathComponent("seen-home.txt").path
        let result = await GrokCLITokenRefresher.runHeadless(
            binary: "/bin/sh",
            grokHome: "/tmp/grok-work",
            arguments: ["-c", "printf '%s' \"$GROK_HOME\" > '\(marker)'"],
            timeout: 5
        )

        #expect(result == true)
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "/tmp/grok-work")
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] {
        lock.withLock { storage }
    }

    func record(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }
}
