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

        // Start reading stdout (FileHandle.bytes yields individual UInt8 values;
        // wrap each as Data for the line-based ACP reader downstream).
        Task {
            let handle = stdoutPipe.fileHandleForReading
            for try await byte in handle.bytes {
                stdoutContinuation.yield(Data([byte]))
            }
            stdoutContinuation.finish()
        }

        // Start reading stderr
        Task {
            let handle = stderrPipe.fileHandleForReading
            for try await byte in handle.bytes {
                stderrContinuation.yield(Data([byte]))
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
