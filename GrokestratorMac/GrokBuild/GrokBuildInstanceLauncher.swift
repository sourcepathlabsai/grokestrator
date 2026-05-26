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

    public init() {}

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
        if let env = config.environmentOverrides {
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }

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

        // Start reading stdout
        Task {
            let handle = stdoutPipe.fileHandleForReading
            for try await data in handle.bytes {
                stdoutContinuation.yield(data)
            }
            stdoutContinuation.finish()
        }

        // Start reading stderr
        Task {
            let handle = stderrPipe.fileHandleForReading
            for try await data in handle.bytes {
                stderrContinuation.yield(data)
            }
            stderrContinuation.finish()
        }

        do {
            try process.run()
            runningProcesses[config.id] = process

            // Monitor for termination
            Task {
                process.waitUntilExit()
                await self.handleProcessExit(config.id, exitCode: process.terminationStatus)
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

    private func handleProcessExit(_ id: UUID, exitCode: Int32) async {
        runningProcesses.removeValue(forKey: id)
        stdoutHandlers[id]?.finish()
        stderrHandlers[id]?.finish()
        stdoutHandlers.removeValue(forKey: id)
        stderrHandlers.removeValue(forKey: id)

        // TODO: Notify higher layers (ServerState, etc.) that the instance died
        print("Grok Build instance \(id) exited with code \(exitCode)")
    }
}

public struct GrokBuildInstanceHandle {
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

    public var errorDescription: String? {
        switch self {
        case .instanceAlreadyRunning(let id):
            return "Instance \(id) is already running"
        case .failedToLaunch(let id, _):
            return "Failed to launch Grok Build instance \(id)"
        case .protocolError(let message):
            return "Grok Build protocol error: \(message)"
        }
    }
}
