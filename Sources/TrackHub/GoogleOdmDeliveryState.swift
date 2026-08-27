import Foundation

/// Serial-queue state for the bounded first-open ODM hold. Keeping the
/// transition rules in one value type makes the timeout/provider/privacy race
/// deterministic and lets the production transitions be regression-tested as
/// a sequence rather than as unrelated predicates.
@_spi(Testing) public struct GoogleOdmDeliveryState: Equatable {
    @_spi(Testing) public enum CompletionOutcome: Equatable {
        /// The callback belongs to an earlier start/fetch generation.
        case stale
        /// The current fetch finished. `cacheAndRefreshInstall` is true only
        /// when the result is valid and measurement is still permitted.
        case completed(cacheAndRefreshInstall: Bool, releasedDeliveryHold: Bool)
    }

    private var fetchGeneration: UUID?
    private var delayGeneration: UUID?

    public init() {}

    public var deliveryDelayActive: Bool { delayGeneration != nil }

    /// Starts a new generation and invalidates every previous callback.
    public mutating func start(token: UUID?, delayDelivery: Bool) {
        fetchGeneration = token
        delayGeneration = delayDelivery ? token : nil
    }

    /// Releases only the delivery hold. The matching fetch remains current so
    /// a late provider callback can enrich a still-buffered install or later
    /// conversion reports.
    @discardableResult
    public mutating func expire(token: UUID) -> Bool {
        guard delayGeneration == token else { return false }
        delayGeneration = nil
        return true
    }

    /// Completes the current generation exactly once. Privacy stop and runtime
    /// circuit suppress caching while still consuming the callback.
    public mutating func complete(
        token: UUID,
        privacyStopped: Bool,
        runtimeCircuitOpen: Bool,
        hasValidInfo: Bool
    ) -> CompletionOutcome {
        guard fetchGeneration == token else { return .stale }
        fetchGeneration = nil
        let releasedDeliveryHold = delayGeneration == token
        if releasedDeliveryHold { delayGeneration = nil }
        return .completed(
            cacheAndRefreshInstall: TrackHub.shouldAcceptGoogleOnDeviceMeasurementInfo(
                hasMatchingGeneration: true,
                privacyStopped: privacyStopped,
                runtimeCircuitOpen: runtimeCircuitOpen,
                hasValidInfo: hasValidInfo
            ),
            releasedDeliveryHold: releasedDeliveryHold
        )
    }

    public mutating func cancel() {
        fetchGeneration = nil
        delayGeneration = nil
    }
}
