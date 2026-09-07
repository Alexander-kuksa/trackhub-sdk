import Foundation

/// A provider result with bounded diagnostic categories. Descriptions never
/// contain Google's opaque payload or an underlying error message/URL.
public enum TrackHubGoogleOdmResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case available(String)
    case noInfo
    case networkError
    case providerError
    case unsupported

    public var info: String? {
        guard case let .available(value) = self, !value.isEmpty, value.utf8.count <= 4096 else { return nil }
        return value
    }

    public var diagnosticReason: String {
        switch self {
        case .available: return info == nil ? "odm_provider_error" : "odm_available"
        case .noInfo: return "odm_empty"
        case .networkError: return "odm_network_error"
        case .providerError: return "odm_provider_error"
        case .unsupported: return "odm_unsupported"
        }
    }

    public var description: String { diagnosticReason }
    public var debugDescription: String { diagnosticReason }

    /// Used by the official bridge. Error details are classified, never logged
    /// or persisted; an error wins even if a provider also supplies partial info.
    public static func fromProvider(info: String?, error: Error?) -> Self {
        if let error {
            return (error as NSError).domain == NSURLErrorDomain ? .networkError : .providerError
        }
        guard let info, !info.isEmpty else { return .noInfo }
        return .available(info)
    }
}

public typealias TrackHubGoogleOdmResultProvider = @MainActor @Sendable (
    _ firstOpenAt: Date,
    _ completion: @escaping @Sendable (TrackHubGoogleOdmResult) -> Void
) -> Void
