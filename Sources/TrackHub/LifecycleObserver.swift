#if os(iOS)
import Foundation
import UIKit

/// Bridges UIApplication foreground/background notifications to the (pure)
/// SessionTracker. iOS-only; excluded from the macOS parity build, so the
/// session state machine itself is tested directly via SessionTracker.
final class LifecycleObserver {
    private let onForeground: () -> Void
    private let onBackground: () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {
        self.onForeground = onForeground
        self.onBackground = onBackground
        let nc = NotificationCenter.default
        // keep the returned tokens so deinit can deregister (the block-based API
        // registers an opaque observer, not `self`).
        tokens.append(
            nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.onForeground() }
        )
        tokens.append(
            nc.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.onBackground() }
        )
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
#endif
