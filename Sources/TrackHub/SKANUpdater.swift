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
  @MainActor private static let writer = AppleAttributionWriter(
    api: SystemAppleAttributionAPI(),
    isSuppressed: { TrackHub.appleAttributionWritesSuppressed() }
  )

  @MainActor static func configure(mode: TrackHubAppleAttributionMode, integrationTest: Bool)
    -> AppleAttributionPermit?
  {
    writer.configure(mode: mode, integrationTest: integrationTest)
  }

  static func registerForAttribution(permit: AppleAttributionPermit) {
    Task { @MainActor in await writer.register(permit: permit) }
  }

  static func apply(
    _ update: ConversionUpdate, adAttributionTarget: AdAttributionConversionTarget,
    conversionTag: String?, permit: AppleAttributionPermit
  ) {
    Task { @MainActor in
      await writer.apply(update, target: adAttributionTarget, tag: conversionTag, permit: permit)
    }
  }
}

/// Only AppleAttributionWriter may invoke this native adapter.
@MainActor
private struct SystemAppleAttributionAPI: AppleAttributionAPI {
  /// Applies a conversion update using the richest API available:
  /// iOS 16.1+ — fine + coarse + lockWindow; 15.4+ — fine only; 14.0+ — legacy.
  func updateSKAN(_ update: ConversionUpdate) {
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
        if let coarse {
          SKAdNetwork.updatePostbackConversionValue(
            update.fine,
            coarseValue: coarse,
            lockWindow: update.lockWindow
          ) { error in
            if let error { TrackHub.log("SKAN update failed: \(error.localizedDescription)") }
          }
        } else {
          // Absence is meaningful: do not manufacture `.low` when the
          // server schema intentionally has no coarse conversion value.
          SKAdNetwork.updatePostbackConversionValue(update.fine) { error in
            if let error { TrackHub.log("SKAN update failed: \(error.localizedDescription)") }
          }
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

  func registerSKAN() {
    #if os(iOS)
      if #available(iOS 15.4, *) {
        SKAdNetwork.updatePostbackConversionValue(0) { _ in }
      } else {
        SKAdNetwork.registerAppForAdNetworkAttribution()
      }
    #endif
  }

  func registerAAK() async {
    #if os(iOS) && canImport(AdAttributionKit)
      if #available(iOS 17.4, *) { await registerAdAttributionKit() }
    #endif
  }

  func updateAAK(_ update: ConversionUpdate, target: AdAttributionConversionTarget, tag: String?)
    async
  {
    #if os(iOS) && canImport(AdAttributionKit)
      if #available(iOS 17.4, *) {
        await applyAdAttributionKit(update, target: target, conversionTag: tag)
      }
    #endif
  }

  #if os(iOS) && canImport(AdAttributionKit)
    @available(iOS 17.4, *)
    private func registerAdAttributionKit() async {
      if #available(iOS 18.0, *), !Postback.isSupported { return }
      do {
        try await Postback.updateConversionValue(0, lockPostback: false)
      } catch {
        TrackHub.log("AdAttributionKit registration failed: \(error.localizedDescription)")
      }
    }

    @available(iOS 17.4, *)
    private func applyAdAttributionKit(
      _ update: ConversionUpdate,
      target: AdAttributionConversionTarget,
      conversionTag: String?
    ) async {
      if #available(iOS 18.0, *), !Postback.isSupported { return }
      let coarse: AdAttributionKit.CoarseConversionValue? = update.coarse.flatMap {
        switch $0 {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        default: return nil
        }
      }
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

    @available(iOS 18.0, *)
    private func conversionTypes(
      _ target: AdAttributionConversionTarget
    ) -> [PostbackUpdate.ConversionType]? {
      switch target {
      case .all: return nil
      case .install: return [.install]
      case .reengagement: return [.reengagement]
      }
    }
  #endif
}
