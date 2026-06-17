import Foundation

/// Detection + assisted install for running **Claude Code** as a Grokestrator Node
/// over ACP. Claude Code has no native ACP, so we drive it through the
/// `@zed-industries/claude-code-acp` adapter (stdio). The prerequisite chain is
/// Claude Code + Homebrew (user-installed) → node + adapter (Grokestrator can
/// install). All shell-outs use a **login shell** so the full PATH/profile is in
/// scope (a Finder-launched .app otherwise has a stripped environment).
enum ClaudeCodeSetup {
    static let adapterPackage = "@zed-industries/claude-code-acp"
    static let adapterBin = "claude-code-acp"

    /// Result of probing the host for the prerequisite chain. Absolute paths when
    /// found, `nil` when missing.
    struct Probe: Sendable, Equatable {
        var claudePath: String?
        var brewPath: String?
        var nodePath: String?
        var npmPath: String?
        var adapterPath: String?

        var claudeOK: Bool { claudePath != nil }
        var homebrewOK: Bool { brewPath != nil }
        var nodeOK: Bool { nodePath != nil && npmPath != nil }
        var adapterOK: Bool { adapterPath != nil }
        /// Ready to create a Claude Code Node: Claude installed + adapter resolvable.
        var ready: Bool { claudeOK && adapterOK }
    }

    /// Probe all prerequisites in one login-shell call.
    static func detect() async -> Probe {
        let sep = "@@GK_SEP@@"
        let cmd = ["claude", "brew", "node", "npm", adapterBin]
            .map { "command -v \($0) 2>/dev/null" }
            .joined(separator: "; echo \(sep); ")
        let (out, _) = await run(cmd, timeout: 30)
        let parts = out.components(separatedBy: sep)
        func path(_ i: Int) -> String? {
            guard i < parts.count else { return nil }
            return parts[i].split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("/") }
        }
        return Probe(claudePath: path(0), brewPath: path(1),
                     nodePath: path(2), npmPath: path(3), adapterPath: path(4))
    }

    /// Resolve the adapter's absolute path — `command -v`, then the npm global bin.
    static func resolveAdapterPath() async -> String? {
        let (out, code) = await run("command -v \(adapterBin) 2>/dev/null", timeout: 30)
        if code == 0, let p = firstPath(out) { return p }
        let (pfx, c) = await run("npm prefix -g 2>/dev/null", timeout: 30)
        if c == 0, let base = firstPath(pfx) {
            let candidate = base + "/bin/\(adapterBin)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `brew install node` (Homebrew must be present). Streams nothing; returns the
    /// combined output + exit code for the panel's log.
    static func installNode() async -> (output: String, exitCode: Int32) {
        await run("brew install node", timeout: 600)
    }

    /// `npm install -g @zed-industries/claude-code-acp` (node/npm must be present).
    static func installAdapter() async -> (output: String, exitCode: Int32) {
        await run("npm install -g \(adapterPackage)", timeout: 600)
    }

    // MARK: - Shell

    private static func firstPath(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("/") }
    }

    /// Run `command` in a login shell (`/bin/zsh -l -c`) off the main actor, with a
    /// watchdog. Returns combined stdout+stderr and the exit code.
    static func run(_ command: String, timeout: TimeInterval = 300) async -> (output: String, exitCode: Int32) {
        final class Box: @unchecked Sendable { let p = Process() }
        let box = Box()
        return await Task.detached(priority: .userInitiated) { [box] () -> (String, Int32) in
            let p = box.p
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return ("failed to launch: \(error.localizedDescription)", -1) }
            let watchdog = Task { [box] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if box.p.isRunning { box.p.terminate() }
            }
            // Read to EOF before waiting, so a large install log can't deadlock the pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
        }.value
    }
}
