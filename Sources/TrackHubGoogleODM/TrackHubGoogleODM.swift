import Foundation
import TrackHub

#if os(iOS) && !targetEnvironment(macCatalyst)
import GoogleAdsOnDeviceConversion
#endif

/// Optional official Google On-Device Measurement bridge for TrackHub.
///
/// Select the `TrackHubGoogleODM` package product and call `start` instead of
/// `TrackHub.start`. The bridge uses TrackHub's durable `firstOpenAt`, fetches
/// Google's opaque installation signal asynchronously, and lets TrackHub's
/// bounded fail-silent timer release delivery on nil/error/timeout.
public enum TrackHubGoogleODM {
    @MainActor
    public static func start(_ configuration: TrackHubConfig) {
        TrackHub.start(configurationWithDefaultProvider(configuration))
    }

    // Preserve the host's Apple attribution mode and consent settings. ODM
    // collection is independent from ownership of SKAN/AdAttributionKit.
    static func configurationWithDefaultProvider(_ configuration: TrackHubConfig) -> TrackHubConfig {
        var enriched = configuration
        if enriched.googleOnDeviceMeasurementInfoProvider == nil,
           enriched.googleOnDeviceMeasurementResultProvider == nil,
           enriched.googleOnDeviceMeasurementInfo == nil {
            enriched.googleOnDeviceMeasurementResultProvider = resultProvider
        }
        return enriched
    }

    public static let provider: TrackHubGoogleOnDeviceMeasurementInfoProvider = {
        firstOpenAt, completion in
        resultProvider(firstOpenAt) { completion($0.info) }
    }

    public static let resultProvider: TrackHubGoogleOdmResultProvider = {
        firstOpenAt,
        completion in
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let manager = ConversionManager.sharedInstance
        manager.setFirstLaunchTime(firstOpenAt)
        manager.fetchAggregateConversionInfo(for: .installation) { info, error in
            completion(.fromProvider(info: info, error: error))
        }
        #else
        completion(.unsupported)
        #endif
    }
}
