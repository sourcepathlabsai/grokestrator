import AppKit
import Foundation

/// Bridges `applicationWillTerminate` into `GrokestratorModel.shutdownAll()` so
/// quitting Grokestrator actually terminates the grok child processes it
/// launched — instead of leaving them as launchd orphans (the user-observed
/// "the grok session has been alive the whole time" problem).
///
/// The model registers itself here in its init via a weak static reference.
/// `applicationWillTerminate` is synchronous; we kick the async cleanup on a
/// Task and block the main thread on a bounded semaphore so the OS gives us a
/// reasonable window to finish before SIGKILLing us.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from `GrokestratorModel.init` (weak so we don't hold the model alive).
    nonisolated(unsafe) static weak var model: GrokestratorModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let model = Self.model else { return }
        let sem = DispatchSemaphore(value: 0)
        // The model is MainActor-isolated; hop to it from a detached task so we
        // don't deadlock the main thread we're about to block on the semaphore.
        Task.detached {
            await MainActor.run {
                Task { await model.shutdownAll(timeout: 1.0); sem.signal() }
            }
        }
        // Bound the wait. macOS gives apps a few seconds; we cap at ~2s so a
        // single hung child can't keep the user staring at a spinning cursor.
        _ = sem.wait(timeout: .now() + 2.0)
    }
}
