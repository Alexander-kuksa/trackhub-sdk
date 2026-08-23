import Foundation

/// Durable storage for the installation's first observed launch timestamp.
///
/// `fot` is a Google App Conversion identity anchor. Returning a timestamp
/// before it is durably stored can create a different value after a hard kill,
/// splitting one installation across multiple conversion timelines.
@_spi(Testing) public enum FirstOpenStore {
    public enum Resolution: Equatable {
        case durable(Date)
        case storageFailure(Date)

        public var value: Date {
            switch self {
            case .durable(let value), .storageFailure(let value): return value
            }
        }

        public var isDurable: Bool {
            if case .durable = self { return true }
            return false
        }
    }

    private static let lock = NSLock()
    private static var volatileValues: [String: String] = [:]
    private static let filename = "trackhub_first_open_at_v1.txt"

    public static func defaultFileURL() -> URL {
        let manager = FileManager.default
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return root
            .appendingPathComponent("TrackHub", isDirectory: true)
            .appendingPathComponent(filename)
    }

    public static func resolve(
        defaults: UserDefaults = .standard,
        legacyKey: String = "trackhub.first_open_at",
        fileURL: URL = defaultFileURL(),
        now: () -> Date = Date.init
    ) -> Resolution {
        lock.lock()
        defer { lock.unlock() }

        let path = fileURL.path
        let legacy = valid(defaults.string(forKey: legacyKey))
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            if let stored = read(fileURL) {
                volatileValues[path] = stored.raw
                defaults.set(stored.raw, forKey: legacyKey)
                return .durable(stored.date)
            }
            // A valid compatibility mirror repairs a corrupt file without
            // inventing a second first-open timestamp.
            if let legacy, persist(legacy.raw, to: fileURL) {
                volatileValues[path] = legacy.raw
                return .durable(legacy.date)
            }
            let fallback = volatileValues[path]
                .flatMap(valid)
                ?? legacy
                ?? canonical(now())
            volatileValues[path] = fallback.raw
            return .storageFailure(fallback.date)
        }

        // Preserve the 3.0.0–3.0.5 UserDefaults value on upgrade. The direct
        // file becomes the source of truth after this one-time migration.
        let candidate = legacy
            ?? volatileValues[path].flatMap(valid)
            ?? canonical(now())
        volatileValues[path] = candidate.raw
        guard persist(candidate.raw, to: fileURL) else {
            return .storageFailure(candidate.date)
        }
        defaults.set(candidate.raw, forKey: legacyKey)
        return .durable(candidate.date)
    }

    @discardableResult
    public static func remove(
        defaults: UserDefaults = .standard,
        legacyKey: String = "trackhub.first_open_at",
        fileURL: URL = defaultFileURL()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: legacyKey)
        volatileValues.removeValue(forKey: fileURL.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    private static func formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private static func canonical(_ date: Date) -> (raw: String, date: Date) {
        let raw = formatter().string(from: date)
        return (raw, formatter().date(from: raw) ?? date)
    }

    private static func valid(_ raw: String?) -> (raw: String, date: Date)? {
        guard let raw,
              raw.utf8.count <= 64,
              let date = formatter().date(from: raw)
        else { return nil }
        return (raw, date)
    }

    private static func read(_ fileURL: URL) -> (raw: String, date: Date)? {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 64,
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        return valid(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func persist(_ value: String, to fileURL: URL) -> Bool {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(directoryValues)

            try Data(value.utf8).write(to: fileURL, options: .atomic)
            #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            #endif
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutableFile = fileURL
            try mutableFile.setResourceValues(fileValues)
            return read(fileURL)?.raw == value
        } catch {
            return false
        }
    }
}
