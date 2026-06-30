import AppKit

/// Keeps the Dock badge and bounce in sync when Connections need the user's
/// attention (permission / question overlays). Bounces only on a *new* need
/// (attention count rising), not on every queued permission in a batch, and only
/// while the app isn't frontmost. Cancels the bounce once the app is activated.
@MainActor
final class DockAttentionCoordinator {
    static let enabledKey = "dockBounceOnAttention"

    private var pendingRequestID: Int?
    private var lastAttentionCount = 0

    func updateAttentionCount(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil

        let bounceEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard bounceEnabled else {
            cancelBounce()
            lastAttentionCount = count
            return
        }

        if count > lastAttentionCount, count > 0, !NSApp.isActive {
            requestBounce()
        }
        if count == 0 {
            cancelBounce()
        }
        lastAttentionCount = count
    }

    func applicationDidBecomeActive() {
        cancelBounce()
    }

    private func requestBounce() {
        guard pendingRequestID == nil else { return }
        pendingRequestID = NSApp.requestUserAttention(.criticalRequest)
    }

    private func cancelBounce() {
        if let id = pendingRequestID {
            NSApp.cancelUserAttentionRequest(id)
            pendingRequestID = nil
        }
    }
}