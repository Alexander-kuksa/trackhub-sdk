import Foundation
#if os(iOS)
import StoreKit
import AdServices
#endif

/// Thin wrapper over SKAdNetwork / AdAttributionKit availability tiers.
/// Platform-independent callers (and macOS unit tests) never touch StoreKit.
enum SKANUpdater {
    /// Applies a conversion update using the richest API available:
    /// iOS 16.1+ — fine + coarse + lockWindow; 15.4+ — fine only; 14.0+ — legacy.
    static func apply(_ update: ConversionUpdate) {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            let coarse: SKAdNetwork.CoarseConversionValue? = update.coarse.flatMap {
                switch $0 {
                case "low": return .low
                case "medium": return .medium
                case "high": return .high
                default: return nil
                }
            }
            SKAdNetwork.updatePostbackConversionValue(
                update.fine,
                coarseValue: coarse ?? .low,
                lockWindow: update.lockWindow
            ) { error in
                if let error { TrackHub.log("SKAN update failed: \(error.localizedDescription)") }
            }
        } else if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(update.fine) { error in
                if let error { TrackHub.log("SKAN update failed: \(error.localizedDescription)") }
            }
        } else {
            SKAdNetwork.updateConversionValue(update.fine)
        }
        #endif
    }

    static func registerForAttribution() {
        #if os(iOS)
        if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { _ in }
        } else {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
    }

    /// AdServices attribution token — resolved server-side by the platform.
    /// Returns nil on simulators and macOS.
    static func attributionToken() -> String? {
        #if os(iOS)
        if #available(iOS 14.3, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }
}
