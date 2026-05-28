import Foundation

/// Resolves the user's interactive login-shell environment, so grok child
/// processes get the same `PATH` and exported variables a Terminal session has —
/// not the stripped environment a Finder-launched `.app` inherits.
///
/// Why this matters: a GUI-launched app gets a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), missing Homebrew, node/`npx`, `uvx`,
/// `~/.grok/bin`, etc. grok then can't spawn its MCP servers, and PATH/helper-
/// dependent tools (including the `imagine` image/video tool) silently fail —
/// grok falls back to bash. Launching grok with the real shell environment fixes
/// both. (See the "launched-grok-environment" note.)
enum LoginShellEnvironment {
    /// Resolved once per app run — rc files don't change mid-session. `static let`
    /// gives a thread-safe, single-shot initialization.
    static let shared: [String: String] = resolve()

    /// Warms the cache off the main/actor executors so the first launch doesn't
    /// pay the shell-spawn latency. Safe to call repeatedly.
    static func warm() {
        Task.detached(priority: .utility) { _ = LoginShellEnvironment.shared }
    }

    private static func resolve() -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        guard let shell = base["SHELL"], !shell.isEmpty,
              FileManager.default.isExecutableFile(atPath: shell) else {
            return withFallbackPath(base)
        }

        // Ask a login+interactive shell to print its environment. A sentinel
        // brackets the block so any rc banner/chatter on stdout is ignored.
        let sentinel = "__GROKESTRATOR_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo \(sentinel); /usr/bin/env; echo \(sentinel)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return withFallbackPath(base) }

        let data = readToEnd(pipe.fileHandleForReading, process: process, timeout: 5)
        guard let text = String(data: data, encoding: .utf8) else { return withFallbackPath(base) }

        var resolved = base
        for (k, v) in parseEnv(text, sentinel: sentinel) { resolved[k] = v }
        return withFallbackPath(resolved)
    }

    /// Reads the pipe to EOF, terminating the process if it overruns `timeout`
    /// (so a misbehaving rc file can't wedge launches).
    ///
    /// The captured `Data` lives in a class box rather than a `var` because
    /// Swift 6 strict concurrency (rightly) refuses to let a closure mutate
    /// a stack-local `var` from another thread, even though our semaphore
    /// makes the access actually safe. `@unchecked Sendable` documents that
    /// we own the synchronization manually.
    private static func readToEnd(_ fh: FileHandle, process: Process, timeout: Double) -> Data {
        final class DataBox: @unchecked Sendable { var value = Data() }
        let box = DataBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = fh.readDataToEndOfFile()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = sem.wait(timeout: .now() + 1)
        } else {
            process.waitUntilExit()
        }
        return box.value
    }

    /// Extracts the `KEY=VALUE` lines between the two sentinel markers.
    private static func parseEnv(_ text: String, sentinel: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: sentinel) else { return [:] }
        let end = lines[(start + 1)...].firstIndex(of: sentinel) ?? lines.endIndex
        var env: [String: String] = [:]
        for line in lines[(start + 1)..<end] {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = String(line[..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue } // skip value continuations
            env[key] = String(line[line.index(after: eq)...])
        }
        return env
    }

    /// Guarantees the common tool directories are on `PATH`, even if shell
    /// resolution was partial or failed.
    private static func withFallbackPath(_ env: [String: String]) -> [String: String] {
        var env = env
        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                      "\(home)/.grok/bin", "\(home)/.local/bin",
                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extras where !parts.contains(dir) { parts.append(dir) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }
}
