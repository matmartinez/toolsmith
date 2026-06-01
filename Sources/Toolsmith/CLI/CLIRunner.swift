import Foundation

/// One-shot CLI invocation result. Captured stdout and stderr are
/// returned as raw bytes so callers can decode as UTF-8 (the common
/// case) or hand the bytes to a binary content block.
public struct CLIInvocationResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Spawn `executable` with the given argv, capturing stdout + stderr
/// and waiting for exit. Synchronous under the hood (Foundation's
/// Process) but exposed as async so callers don't block their actor.
public func runCLI(
    executable: URL,
    args: [String],
    env: [String: String]? = nil,
    cwd: URL? = nil
) async throws -> CLIInvocationResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    if let env { process.environment = env }
    if let cwd { process.currentDirectoryURL = cwd }
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardInput = FileHandle.nullDevice
    process.standardError = stderrPipe

    try process.run()
    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CLIInvocationResult(
        stdout: stdout,
        stderr: stderr,
        exitCode: process.terminationStatus
    )
}
