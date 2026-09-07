import Foundation

/// Eligibility is recorded when an event is buffered during the initial
/// ATT/ODM hold. It is not inferred for legacy queues or later app sessions.
@_spi(Testing) public struct FirstOpenReportEnrichment: Codable, Equatable {
    public let installUid: String
    public let expiresAt: Date
    public let allowAdvertisingId: Bool

    public init(installUid: String, expiresAt: Date, allowAdvertisingId: Bool) {
        self.installUid = installUid
        self.expiresAt = expiresAt
        self.allowAdvertisingId = allowAdvertisingId
    }

    public static let maximumAge: TimeInterval = 10 * 60
    public static let paths: Set<String> = ["install", "sdk/session", "sdk/track", "sdk/purchase-context"]

    /// Only signal metadata may change. IDs, economic data, event time, click
    /// IDs and first_open_at are preserved from the event's original snapshot.
    public func bodyForFirstDispatch(
        report: PendingReport,
        currentInstallUid: String,
        signals: [String: Any],
        measurementAllowed: Bool,
        now: Date
    ) -> Data? {
        guard !report.hasBeenDispatched, report.attempts == 0,
              Self.paths.contains(report.path), installUid == currentInstallUid,
              var body = try? JSONSerialization.jsonObject(with: report.body) as? [String: Any],
              body["install_uid"] as? String == installUid else { return nil }

        let currentIdfaAllowed = allowAdvertisingId
            && signals["device_id_type"] as? String == "idfa"
            && signals["limit_ad_tracking"] as? Bool == false
        let mustRemoveIdfa = body["device_id_type"] as? String == "idfa" && !currentIdfaAllowed
        if mustRemoveIdfa {
            body.removeValue(forKey: "device_id")
            body.removeValue(forKey: "device_id_type")
            body.removeValue(forKey: "limit_ad_tracking")
        }

        // Explicit consent withdrawal wins even when the enrichment window
        // has elapsed. Do not attach new identifiers to denied event snapshots.
        if !measurementAllowed {
            body.removeValue(forKey: "odm_info")
            body.removeValue(forKey: "device_id")
            body.removeValue(forKey: "device_id_type")
            body.removeValue(forKey: "limit_ad_tracking")
        } else {
            guard now >= report.createdAt, now <= expiresAt else {
                return mustRemoveIdfa ? try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) : nil
            }
            if let info = signals["odm_info"] as? String, !info.isEmpty, info.utf8.count <= 4096 {
                body["odm_info"] = info
            }
            if let type = signals["device_id_type"] as? String,
               type == "idfv" || (type == "idfa" && allowAdvertisingId),
               let id = signals["device_id"] as? String,
               let uuid = UUID(uuidString: id), uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
               let lat = signals["limit_ad_tracking"] as? Bool,
               type != "idfa" || lat == false {
                body["device_id"] = id
                body["device_id_type"] = type
                body["limit_ad_tracking"] = lat
            }
        }
        return try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
}
