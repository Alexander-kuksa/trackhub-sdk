import Foundation

// These types are SDK internals (schema decode + SKAN encoder). They are SPI —
// hidden from the app-facing TrackHub API; the macOS parity tests reach them via
// `@_spi(Testing) import TrackHub`.

/// Conversion value schema served by the platform (`GET /ingest/{token}/cv-schema`).
/// Mirrors `CvSchema` in the backend — the encoder stays in lockstep with
/// `encodeConversionValue` there.
@_spi(Testing) public struct ConversionSchema: Codable, Equatable {
    @_spi(Testing) public struct Rule: Codable, Equatable {
        public let from: Int
        public let to: Int
        public let event: String
        public let revenueLowCents: Int?
        public let revenueHighCents: Int?
        public let coarse: String?

        public init(
            from: Int, to: Int, event: String,
            revenueLowCents: Int? = nil, revenueHighCents: Int? = nil, coarse: String? = nil
        ) {
            self.from = from
            self.to = to
            self.event = event
            self.revenueLowCents = revenueLowCents
            self.revenueHighCents = revenueHighCents
            self.coarse = coarse
        }
    }

    public let schemaVersion: Int
    public let rules: [Rule]
    public let lockOnEvents: [String]

    public init(schemaVersion: Int, rules: [Rule], lockOnEvents: [String] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.lockOnEvents = lockOnEvents
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, lockOnEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        lockOnEvents = try container.decodeIfPresent([String].self, forKey: .lockOnEvents) ?? []
    }
}

/// Result of encoding an app event into SKAN/AdAttributionKit conversion values.
@_spi(Testing) public struct ConversionUpdate: Equatable {
    public let fine: Int
    /// "low" | "medium" | "high" | nil
    public let coarse: String?
    public let lockWindow: Bool

    public init(fine: Int, coarse: String?, lockWindow: Bool) {
        self.fine = fine
        self.coarse = coarse
        self.lockWindow = lockWindow
    }
}

/// Exact fine/coarse/lock bits calculated from authenticated server activity.
/// Event names and revenue never need to cross back into the app.
@_spi(Testing) public struct ServerConversionInstruction: Codable, Equatable {
    public let schemaVersion: Int
    public let window: Int
    public let fine: Int
    public let coarse: String?
    public let lockWindow: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case window, fine, coarse
        case lockWindow = "lock_window"
    }

    public var update: ConversionUpdate? {
        guard (0...2).contains(window), (0...63).contains(fine), schemaVersion >= 0 else { return nil }
        if let coarse, !["low", "medium", "high"].contains(coarse) { return nil }
        return ConversionUpdate(fine: fine, coarse: coarse, lockWindow: lockWindow)
    }
}

@_spi(Testing) public struct ServerConversionEnvelope: Codable, Equatable {
    public let conversionUpdate: ServerConversionInstruction?

    enum CodingKeys: String, CodingKey {
        case conversionUpdate = "conversion_update"
    }
}

@_spi(Testing) public enum ConversionEncoder {
    /// event + optional revenue (cents) → fine/coarse/lock. Mirrors the backend
    /// `encodeConversionValue`: revenue is linearly bucketed into the rule's fine
    /// range, clamped at the edges.
    public static func encode(
        schema: ConversionSchema, event: String, revenueCents: Int? = nil
    ) -> ConversionUpdate? {
        guard let rule = schema.rules.first(where: { $0.event == event }) else { return nil }

        var fine = rule.from
        if let revenue = revenueCents,
           let low = rule.revenueLowCents,
           let high = rule.revenueHighCents,
           high > low, rule.to > rule.from {
            let ratio = Double(revenue - low) / Double(high - low)
            let clamped = min(1.0, max(0.0, ratio))
            fine = rule.from + Int((clamped * Double(rule.to - rule.from)).rounded())
        }

        return ConversionUpdate(
            fine: fine,
            coarse: rule.coarse,
            lockWindow: schema.lockOnEvents.contains(event)
        )
    }
}
