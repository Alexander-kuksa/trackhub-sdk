import Foundation
#if os(iOS)
import StoreKit
#endif
#if os(iOS) && canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// Thin wrapper over SKAdNetwork / AdAttributionKit availability tiers.
/// Platform-independent callers (and macOS unit tests) never touch StoreKit.
enum SKANUpdater {
    /// Applies a conversion update using the richest API available:
    /// iOS 16.1+ — fine + coarse + lockWindow; 15.4+ — fine only; 14.0+ — legacy.
    static func apply(
        _ update: ConversionUpdate,
        adAttributionTarget: AdAttributionConversionTarget,
        conversionTag: String?
    ) {
        #if os(iOS)
        if #available(iOS 17.4, *) {
            applyAdAttributionKit(
                update,
                target: adAttributionTarget,
                conversionTag: conversionTag
            )
        }
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
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            registerAdAttributionKit()
        }
        #endif
        if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { _ in }
        } else {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
    }

    #if os(iOS) && canImport(AdAttributionKit)
    @available(iOS 17.4, *)
    private static func registerAdAttributionKit() {
        if #available(iOS 18.0, *), !Postback.isSupported { return }
        Task {
            do {
                try await Postback.updateConversionValue(0, lockPostback: false)
            } catch {
                TrackHub.log("AdAttributionKit registration failed: \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 17.4, *)
    private static func applyAdAttributionKit(
        _ update: ConversionUpdate,
        target: AdAttributionConversionTarget,
        conversionTag: String?
    ) {
        if #available(iOS 18.0, *), !Postback.isSupported { return }
        let coarse: AdAttributionKit.CoarseConversionValue? = update.coarse.flatMap {
            switch $0 {
            case "low": return .low
            case "medium": return .medium
            case "high": return .high
            default: return nil
            }
        }
        Task {
            do {
                if #available(iOS 18.4, *), let tag = conversionTag, !tag.isEmpty {
                    let request = PostbackUpdate(
                        fineConversionValue: update.fine,
                        lockPostback: update.lockWindow,
                        conversionTag: tag,
                        coarseConversionValue: coarse,
                        conversionTypes: conversionTypes(target)
                    )
                    try await Postback.updateConversionValue(request)
                } else if #available(iOS 18.0, *) {
                    let request = PostbackUpdate(
                        fineConversionValue: update.fine,
                        lockPostback: update.lockWindow,
                        coarseConversionValue: coarse,
                        conversionTypes: conversionTypes(target)
                    )
                    try await Postback.updateConversionValue(request)
                } else if let coarse {
                    try await Postback.updateConversionValue(
                        update.fine,
                        coarseConversionValue: coarse,
                        lockPostback: update.lockWindow
                    )
                } else {
                    try await Postback.updateConversionValue(
                        update.fine,
                        lockPostback: update.lockWindow
                    )
                }
            } catch {
                TrackHub.log("AdAttributionKit update failed: \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 18.0, *)
    private static func conversionTypes(
        _ target: AdAttributionConversionTarget
    ) -> [PostbackUpdate.ConversionType]? {
        switch target {
        case .all: return nil
        case .install: return [.install]
        case .reengagement: return [.reengagement]
        }
    }
    #else
    private static func registerAdAttributionKit() {}

    private static func applyAdAttributionKit(
        _ update: ConversionUpdate,
        target: AdAttributionConversionTarget,
        conversionTag: String?
    ) {}
    #endif
}
