import Foundation
import GrokestratorCore

/// Responsible for launching and managing the lifecycle of local Grok Build instances
/// on the Mac (the server role of the hybrid app).
///
/// This is Mac-specific and uses Foundation.Process.
public actor GrokBuildInstanceLauncher {
    private var runningProcesses: [UUID: Process] = [:]
    private var stdoutHandlers: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var stderrHandlers: [UUID: AsyncStream<Data>.Continuation] = [:]

    public init() {
        // Resolve the login-shell environment ahead of the first launch.
        LoginShellEnvironment.warm()
    }

    /// Launches a Grok Build instance based on the provided configuration.
    /// Returns a handle that can be used to communicate with the instance.
    public func launch(_ config: ManagedInstance) async throws -> GrokBuildInstanceHandle {
        guard config.status == .stopped || config.status == .crashed else {
            throw GrokBuildError.instanceAlreadyRunning(config.id)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.command)
        process.arguments = config.arguments
        if let cwd = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        // Launch grok with the user's real login-shell environment (full PATH +
        // exported vars), then layer any per-instance overrides on top. A
        // Finder-launched .app otherwise hands grok a stripped environment, so its
        // MCP servers and PATH/API-dependent tools (e.g. the `imagine` tool) fail
        // and it silently falls back to bash.
        var environment = LoginShellEnvironment.shared
        if let overrides = config.environmentOverrides {
            environment.merge(overrides) { _, new in new }
        }
        process.environment = environment

        // Setup pipes for stdio communication (the primary way we talk to grok build)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Create streams for reading output
        let (stdoutStream, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (stderrStream, stderrContinuation) = AsyncStream<Data>.makeStream()

        stdoutHandlers[config.id] = stdoutContinuation
        stderrHandlers[config.id] = stderrContinuation

        // Stream stdout/stderr in chunks via readability handlers. (Reading
        // byte-by-byte through an AsyncStream stalls on multi-KB ACP messages.)
        let stdoutFH = stdoutPipe.fileHandleForReading
        stdoutFH.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                stdoutContinuation.finish()
                fh.readabilityHandler = nil
            } else {
                stdoutContinuation.yield(data)
            }
        }

        let stderrFH = stderrPipe.fileHandleForReading
        stderrFH.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                stderrContinuation.finish()
                fh.readabilityHandler = nil
            } else {
                stderrContinuation.yield(data)
            }
        }

        do {
            try process.run()
            runningProcesses[config.id] = process

            // Monitor for termination via a callback. Do NOT call
            // process.waitUntilExit() from a Task here: that Task inherits this
            // actor's executor, and waitUntilExit() blocks synchronously —
            // wedging the entire launcher actor for the process's lifetime.
            process.terminationHandler = { proc in
                let exitCode = proc.terminationStatus
                Task { await self.handleProcessExit(config.id, exitCode: exitCode) }
            }

            return GrokBuildInstanceHandle(
                id: config.id,
                process: process,
                stdin: stdinPipe.fileHandleForWriting,
                stdout: stdoutStream,
                stderr: stderrStream
            )
        } catch {
            stdoutContinuation.finish()
            stderrContinuation.finish()
            throw GrokBuildError.failedToLaunch(config.id, underlyingError: error)
        }
    }

    public func terminate(_ id: UUID) async {
        guard let process = runningProcesses[id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: id)
        stdoutHandlers[id]?.finish()
        stderrHandlers[id]?.finish()
        stdoutHandlers.removeValue(forKey: id)
        stderrHandlers.removeValue(forKey: id)
    }

    /// Terminates every running grok process. Sends `SIGTERM` to each, waits up
    /// to `timeout` for graceful exit, then `SIGKILL`s any survivor. Called on
    /// app quit so we don't leave orphan grok processes — the very thing the
    /// user observed ("the grok session has been alive the whole time").
    public func terminateAll(timeout: TimeInterval = 1.0) async {
        let processes = Array(runningProcesses.values)
        let ids = Array(runningProcesses.keys)
        guard !processes.isEmpty else { return }

        for p in processes { p.terminate() }   // SIGTERM, in parallel

        // Wait briefly for graceful exit, polling every 50ms.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processes.allSatisfy({ !$0.isRunning }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Anyone still alive gets SIGKILL.
        for p in processes where p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }

        // Clean up bookkeeping for all of them (handlers may have already finished
        // when the process actually died; .finish() is idempotent).
        for id in ids {
            stdoutHandlers[id]?.finish()
            stderrHandlers[id]?.finish()
            stdoutHandlers.removeValue(forKey: id)
            stderrHandlers.removeValue(forKey: id)
            runningProcesses.removeValue(forKey: id)
        }
    }

    private var exitHandlers: [UUID: @Sendable (UUID, Int32) -> Void] = [:]

    private func handleProcessExit(_ id: UUID, exitCode: Int32) async {
        runningProcesses.removeValue(forKey: id)
        stdoutHandlers[id]?.finish()
        stderrHandlers[id]?.finish()
        stdoutHandlers.removeValue(forKey: id)
        stderrHandlers.removeValue(forKey: id)

        if let handler = exitHandlers[id] {
            handler(id, exitCode)
        }

        print("Grok Build instance \(id) exited with code \(exitCode)")
    }

    /// Register to be notified when a specific instance's process dies.
    public func onInstanceDied(id: UUID, handler: @escaping @Sendable (UUID, Int32) -> Void) {
        exitHandlers[id] = handler
    }

    /// Legacy registration (kept for compatibility).
    public func registerExitHandler(for id: UUID, handler: @escaping @Sendable (UUID, Int32) -> Void) {
        exitHandlers[id] = handler
    }
}

/// Handle to a launched Grok Build process. Wraps OS resources (`Process`,
/// `FileHandle`) that are not themselves `Sendable`. The handle is created once
/// by the launcher and its ownership is handed off to a single
/// `GrokBuildSessionClient`, so crossing the actor boundary at hand-off is safe.
public struct GrokBuildInstanceHandle: @unchecked Sendable {
    public let id: UUID
    public let process: Process
    public let stdin: FileHandle
    public let stdout: AsyncStream<Data>
    public let stderr: AsyncStream<Data>
}

public enum GrokBuildError: Error, LocalizedError {
    case instanceAlreadyRunning(UUID)
    case failedToLaunch(UUID, underlyingError: Error)
    case protocolError(String)
    case instanceManagementError(String)

    public var errorDescription: String? {
        switch self {
        case .instanceAlreadyRunning(let id):
            return "Instance \(id) is already running"
        case .failedToLaunch(let id, _):
            return "Failed to launch Grok Build instance \(id)"
        case .protocolError(let message):
            return "Grok Build protocol error: \(message)"
        case .instanceManagementError(let message):
            return "Grok Build instance management error: \(message)"
        }
    }
}
