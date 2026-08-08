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

public struct TrackHubConfig: Sendable, CustomStringConvertible {
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

    /// Safe for diagnostics: credentials, device identifiers and test tokens
    /// are deliberately omitted so crash reporters cannot capture them.
    public var description: String {
        let environmentDescription: String
        switch environment {
        case .production: environmentDescription = "production"
        case .testLab: environmentDescription = "testLab(<redacted>)"
        }
        return "TrackHubConfig(" +
            "sdkKey=<redacted>, " +
            "environment=\(environmentDescription), " +
            "debugLogging=\(debugLogging), " +
            "countryCode=\(countryCode ?? "nil"), " +
            "attConsentWaitingInterval=\(attConsentWaitingInterval), " +
            "firebaseAppInstanceId=\(firebaseAppInstanceId == nil ? "nil" : "<redacted>"), " +
            "googleOnDeviceMeasurementInfo=\(googleOnDeviceMeasurementInfo == nil ? "nil" : "<redacted>"), " +
            "attributionChangedHandler=\(attributionChangedHandler != nil), " +
            "deferredDeepLinkHandler=\(deferredDeepLinkHandler != nil))"
    }
}

struct DecodedTrackHubSdkKey: Decodable, Equatable {
    let endpoint: URL
    let trackingEndpoint: URL?
    let ingestToken: String
    let sdkSecret: String

    private enum CodingKeys: String, CodingKey {
        case endpoint = "e"
        case trackingEndpoint = "t"
        case ingestToken = "i"
        case sdkSecret = "s"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let endpointString = try values.decode(String.self, forKey: .endpoint)
        let trackingEndpointString = try values.decodeIfPresent(String.self, forKey: .trackingEndpoint)
        let ingestToken = try values.decode(String.self, forKey: .ingestToken)
        let sdkSecret = try values.decode(String.self, forKey: .sdkSecret)
        guard let endpoint = Self.validEndpoint(endpointString),
              trackingEndpointString == nil || Self.validEndpoint(trackingEndpointString!) != nil,
              ingestToken.count >= 20, sdkSecret.count >= 20 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid sdkKey"))
        }
        self.endpoint = endpoint
        self.trackingEndpoint = trackingEndpointString.flatMap(Self.validEndpoint)
        self.ingestToken = ingestToken
        self.sdkSecret = sdkSecret
    }

    private static func validEndpoint(_ value: String) -> URL? {
        guard let endpoint = URL(string: value),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.scheme == "https"
                || ((endpoint.host == "localhost" || endpoint.host == "127.0.0.1") && endpoint.scheme == "http")
        else { return nil }
        return endpoint
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
