import Foundation

/// An app-start-scoped capability. Old asynchronous work cannot acquire the
/// authority of a later start (including a Test Lab -> production transition).
struct AppleAttributionPermit: Sendable, Equatable {
  let id = UUID()
}

@MainActor
protocol AppleAttributionAPI {
  func registerSKAN()
  func registerAAK() async
  func updateSKAN(_ update: ConversionUpdate)
  func updateAAK(_ update: ConversionUpdate, target: AdAttributionConversionTarget, tag: String?)
    async
}

/// The single permission boundary for both Apple APIs. Native calls and
/// configuration are serialized on MainActor. Never hold a lock across await
/// or make SKAN depend on the asynchronous completion of an AAK request.
@MainActor
final class AppleAttributionWriter {
  private let api: any AppleAttributionAPI
  private let isSuppressed: () -> Bool
  private var currentPermit: AppleAttributionPermit?
  private var passiveSelected = false

  init(api: any AppleAttributionAPI, isSuppressed: @escaping () -> Bool = { false }) {
    self.api = api
    self.isSuppressed = isSuppressed
  }

  func configure(mode: TrackHubAppleAttributionMode, integrationTest: Bool)
    -> AppleAttributionPermit?
  {
    // Fail closed on an accidental second start with a default config.
    // This is not a dynamic ownership handoff within an Apple window.
    passiveSelected = passiveSelected || mode == .passive
    currentPermit = !passiveSelected && !integrationTest ? AppleAttributionPermit() : nil
    return currentPermit
  }

  private func allows(_ permit: AppleAttributionPermit) -> Bool {
    currentPermit == permit && !isSuppressed()
  }

  func register(permit: AppleAttributionPermit) async {
    guard allows(permit) else { return }
    api.registerSKAN()
    guard allows(permit) else { return }
    await api.registerAAK()
  }

  func apply(
    _ update: ConversionUpdate, target: AdAttributionConversionTarget,
    tag: String?, permit: AppleAttributionPermit
  ) async {
    guard allows(permit) else { return }
    api.updateSKAN(update)
    guard allows(permit) else { return }
    await api.updateAAK(update, target: target, tag: tag)
  }
}
