import Foundation

/// Conversion value schema served by the TrackHub platform
/// (`GET /ingest/{token}/cv-schema`). Mirrors `CvSchema` in the backend —
/// the encoder below must stay in lockstep with `encodeConversionValue` there.
public struct ConversionSchema: Codable, Equatable {
    public struct Rule: Codable, Equatable {
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

/// Result of encoding an app event into SKAN conversion values.
public struct ConversionUpdate: Equatable {
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

public enum ConversionEncoder {
    /// event + optional revenue (in cents) → fine/coarse/lock. Mirrors the
    /// backend `encodeConversionValue`: revenue is linearly bucketed into the
    /// rule's fine range, clamped at the edges.
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
