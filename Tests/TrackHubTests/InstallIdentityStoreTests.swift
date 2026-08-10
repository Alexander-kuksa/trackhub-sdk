import XCTest
@_spi(Testing) import TrackHub

final class InstallIdentityStoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackhub-install-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "trackhub.install-identity-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (root.appendingPathComponent("install_uid.txt"), defaults, suite)
    }

    private func cleanup(_ file: URL, defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testCreatesDurableIdentityBeforeReturningIt() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }

        let resolution = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: file
        )
        XCTAssertTrue(resolution.isDurable)
        XCTAssertNotNil(UUID(uuidString: resolution.value))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), resolution.value)
        XCTAssertEqual(defaults.string(forKey: "trackhub.install_uid"), resolution.value)
    }

    func testDurableFileWinsAndRepairsMissingMirror() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let first = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: file
        ).value
        defaults.removeObject(forKey: "trackhub.install_uid")

        let second = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: file
        )
        XCTAssertEqual(second, .durable(first))
        XCTAssertEqual(defaults.string(forKey: "trackhub.install_uid"), first)
    }

    func testLegacyIdentityMigratesWithoutRequiringAQueueFile() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let legacy = UUID().uuidString
        defaults.set(legacy, forKey: "trackhub.install_uid")
        let resolution = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: file
        )
        XCTAssertEqual(resolution, .durable(legacy))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), legacy)
    }

    func testStorageFailureNeverPretendsTheIdentityIsDurable() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let blockedParent = file.deletingLastPathComponent().appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedParent)

        let resolution = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: blockedParent.appendingPathComponent("install_uid.txt")
        )
        XCTAssertFalse(resolution.isDurable)
        XCTAssertNotNil(UUID(uuidString: resolution.value))
    }

    func testPrivacyRemovalClearsFileAndMirror() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        _ = InstallIdentityStore.resolve(
            defaults: defaults,
            fileURL: file
        )

        XCTAssertTrue(InstallIdentityStore.remove(defaults: defaults, fileURL: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.string(forKey: "trackhub.install_uid"))
    }

    func testPrivacyRetentionRewritesFileAndMirrorTogether() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let retained = UUID().uuidString

        XCTAssertTrue(InstallIdentityStore.retain(
            retained,
            defaults: defaults,
            fileURL: file
        ))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), retained)
        XCTAssertEqual(defaults.string(forKey: "trackhub.install_uid"), retained)
        XCTAssertEqual(
            InstallIdentityStore.resolve(defaults: defaults, fileURL: file),
            .durable(retained)
        )
    }

    func testInstallScopedEventDeduplicationVector() {
        let installUid = "11111111-2222-4333-8444-555555555555"
        let expected = "dedup1-9068017e11119b7a3c99163c1cb825e87ecda0542a4405cb526d506b941eb579"
        XCTAssertEqual(
            TrackHub.deduplicatedClientEventId(
                installUid: installUid,
                eventName: " tutorial_done ",
                deduplicationId: " order-42 "
            ),
            expected
        )
        XCTAssertNil(TrackHub.deduplicatedClientEventId(
            installUid: installUid,
            eventName: "tutorial_done",
            deduplicationId: "   "
        ))
        XCTAssertNil(TrackHub.deduplicatedClientEventId(
            installUid: installUid,
            eventName: "tutorial_done",
            deduplicationId: String(repeating: "x", count: 257)
        ))
        XCTAssertNotEqual(
            TrackHub.deduplicatedClientEventId(
                installUid: installUid,
                eventName: "tutorial_done",
                deduplicationId: "order-42"
            ),
            TrackHub.deduplicatedClientEventId(
                installUid: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                eventName: "tutorial_done",
                deduplicationId: "order-42"
            )
        )
    }
}
