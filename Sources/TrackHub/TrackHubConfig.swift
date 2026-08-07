import Foundation

public enum TrackHubEnvironment: Sendable, Equatable {
    case production
    case testLab(token: String)

    var testToken: String? {
        guard case let .testLab(token) = self else { return nil }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 20 && value.count <= 128 ? value : nil
    }
}

public enum TrackHubConsentStatus: String, Sendable, Equatable {
    case granted
    case denied
    case unknown

    var boolValue: Bool? {
        switch self {
        case .granted: return true
        case .denied: return false
        case .unknown: return nil
        }
    }
}

public struct TrackHubGoogleAdsConsent: Sendable, Equatable {
    public var adUserData: TrackHubConsentStatus
    public var adPersonalization: TrackHubConsentStatus
    public var isEea: Bool?

    public init(
        adUserData: TrackHubConsentStatus = .unknown,
        adPersonalization: TrackHubConsentStatus = .unknown,
        isEea: Bool? = nil
    ) {
        self.adUserData = adUserData
        self.adPersonalization = adPersonalization
        self.isEea = isEea
    }
}

public struct TrackHubPIPLConsent: Sendable, Equatable {
    public var personalInformation: TrackHubConsentStatus
    public var crossBorderTransfer: TrackHubConsentStatus
    public var adsMeasurement: TrackHubConsentStatus

    public init(
        personalInformation: TrackHubConsentStatus = .unknown,
        crossBorderTransfer: TrackHubConsentStatus = .unknown,
        adsMeasurement: TrackHubConsentStatus = .unknown
    ) {
        self.personalInformation = personalInformation
        self.crossBorderTransfer = crossBorderTransfer
        self.adsMeasurement = adsMeasurement
    }
}

public struct TrackHubConfig: Sendable {
    public let sdkKey: String
    public let environment: TrackHubEnvironment
    public var debugLogging = false
    public var countryCode: String?
    public var attConsentWaitingInterval: TimeInterval = 0
    public var googleAdsConsent = TrackHubGoogleAdsConsent()
    public var piplConsent = TrackHubPIPLConsent()
    public var firebaseAppInstanceId: String?
    public var googleOnDeviceMeasurementInfo: String?
    public var attributionChangedHandler: TrackHubAttributionChangedHandler?
    public var deferredDeepLinkHandler: TrackHubDeferredDeepLinkHandler?

    public init(sdkKey: String, environment: TrackHubEnvironment = .production) {
        self.sdkKey = sdkKey
        self.environment = environment
    }
}

struct DecodedTrackHubSdkKey: Decodable, Equatable {
    let endpoint: URL
    let ingestToken: String
    let sdkSecret: String

    private enum CodingKeys: String, CodingKey { case endpoint = "e", ingestToken = "i", sdkSecret = "s" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let endpointString = try values.decode(String.self, forKey: .endpoint)
        let ingestToken = try values.decode(String.self, forKey: .ingestToken)
        let sdkSecret = try values.decode(String.self, forKey: .sdkSecret)
        guard let endpoint = URL(string: endpointString),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.scheme == "https"
                || ((endpoint.host == "localhost" || endpoint.host == "127.0.0.1") && endpoint.scheme == "http"),
              ingestToken.count >= 20, sdkSecret.count >= 20 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid sdkKey"))
        }
        self.endpoint = endpoint
        self.ingestToken = ingestToken
        self.sdkSecret = sdkSecret
    }

    static func decode(_ value: String) -> DecodedTrackHubSdkKey? {
        let prefix = "thcfg_v1_"
        guard value.hasPrefix(prefix), value.count <= 8192 else { return nil }
        var encoded = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
