import Foundation
import Testing

@testable import Toolsmith

@Suite("CLIRunner")
struct CLIRunnerTests {
    @Test("/bin/echo captures stdout and exits 0")
    func echoStdout() async throws {
        let result = try await runCLI(
            executable: URL(fileURLWithPath: "/bin/echo"),
            args: ["hello", "world"]
        )
        #expect(result.exitCode == 0)
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text == "hello world\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("Non-zero exit code is captured (/bin/sh -c 'exit 7')")
    func nonZeroExit() async throws {
        let result = try await runCLI(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "exit 7"]
        )
        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
    }

    @Test("stderr is captured separately from stdout")
    func stderrCapture() async throws {
        let result = try await runCLI(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo to-out; echo to-err 1>&2; exit 0"]
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "to-out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "to-err\n")
    }

    @Test("env dictionary is propagated to the child")
    func envPropagation() async throws {
        let result = try await runCLI(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            args: ["sh", "-c", "echo $TOOLSMITH_PROBE"],
            env: ["TOOLSMITH_PROBE": "ok-42", "PATH": "/usr/bin:/bin"]
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "ok-42\n")
    }

    @Test("cwd is honored — pwd reports the configured directory")
    func cwdPropagation() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toolsmith-cli-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await runCLI(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            args: [],
            cwd: tmp
        )
        #expect(result.exitCode == 0)
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // pwd may resolve symlinks (e.g. /var → /private/var on macOS), so
        // compare resolved-path suffixes rather than raw strings.
        let resolved = URL(fileURLWithPath: text).resolvingSymlinksInPath().path
        let expected = tmp.resolvingSymlinksInPath().path
        #expect(resolved == expected)
    }

    @Test("Missing executable surfaces as a thrown error")
    func missingExecutable() async {
        await #expect(throws: (any Error).self) {
            _ = try await runCLI(
                executable: URL(fileURLWithPath: "/no/such/binary"),
                args: []
            )
        }
    }
}
