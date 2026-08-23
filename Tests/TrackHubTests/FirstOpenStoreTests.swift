import XCTest
@_spi(Testing) import TrackHub

final class FirstOpenStoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackhub-first-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "trackhub.first-open-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (root.appendingPathComponent("first_open.txt"), defaults, suite)
    }

    private func cleanup(_ file: URL, defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testCreatesDurableCanonicalTimestampBeforeReturningIt() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000.987)

        let resolution = FirstOpenStore.resolve(
            defaults: defaults,
            fileURL: file,
            now: { now }
        )
        XCTAssertTrue(resolution.isDurable)
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(defaults.string(forKey: "trackhub.first_open_at"), stored)
        XCTAssertEqual(ISO8601DateFormatter().date(from: stored), resolution.value)

        // A process-level reread returns exactly the committed timestamp, not
        // the fractional pre-serialization Date from the first call.
        XCTAssertEqual(
            FirstOpenStore.resolve(defaults: defaults, fileURL: file).value,
            resolution.value
        )
    }

    func testDurableFileWinsAndRepairsMissingMirror() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let first = FirstOpenStore.resolve(defaults: defaults, fileURL: file)
        defaults.removeObject(forKey: "trackhub.first_open_at")

        let second = FirstOpenStore.resolve(defaults: defaults, fileURL: file)
        XCTAssertEqual(second, first)
        XCTAssertNotNil(defaults.string(forKey: "trackhub.first_open_at"))
    }

    func testLegacyTimestampMigratesWithoutChangingFirstOpen() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let legacy = "2026-08-21T12:34:56Z"
        defaults.set(legacy, forKey: "trackhub.first_open_at")

        let resolution = FirstOpenStore.resolve(defaults: defaults, fileURL: file)
        XCTAssertEqual(resolution.value, ISO8601DateFormatter().date(from: legacy))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), legacy)
    }

    func testCorruptFileIsRepairedFromValidMirror() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let legacy = "2026-08-21T12:34:56Z"
        defaults.set(legacy, forKey: "trackhub.first_open_at")
        try Data("corrupt".utf8).write(to: file)

        let resolution = FirstOpenStore.resolve(defaults: defaults, fileURL: file)
        XCTAssertTrue(resolution.isDurable)
        XCTAssertEqual(resolution.value, ISO8601DateFormatter().date(from: legacy))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), legacy)
    }

    func testStorageFailureIsStableButNeverReportedAsDurable() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        let blockedParent = file.deletingLastPathComponent().appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let target = blockedParent.appendingPathComponent("first_open.txt")

        let first = FirstOpenStore.resolve(
            defaults: defaults,
            fileURL: target,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let second = FirstOpenStore.resolve(
            defaults: defaults,
            fileURL: target,
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        XCTAssertFalse(first.isDurable)
        XCTAssertFalse(second.isDurable)
        XCTAssertEqual(first.value, second.value)
        XCTAssertNil(defaults.string(forKey: "trackhub.first_open_at"))
    }

    func testPrivacyRemovalClearsFileAndMirror() throws {
        let (file, defaults, suite) = try fixture()
        defer { cleanup(file, defaults: defaults, suite: suite) }
        _ = FirstOpenStore.resolve(defaults: defaults, fileURL: file)

        XCTAssertTrue(FirstOpenStore.remove(defaults: defaults, fileURL: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.string(forKey: "trackhub.first_open_at"))
    }
}
