import Foundation

/// Durable, installation-scoped storage for TrackHub's measurement identity.
///
/// SDK 3.0.0–3.0.3 stored the identifier only in UserDefaults. UserDefaults can
/// be restored onto another device and does not expose a confirmed durable-write
/// boundary. The file is therefore the source of truth from 3.0.3 onward;
/// UserDefaults remains a compatibility mirror only.
@_spi(Testing) public enum InstallIdentityStore {
    public enum Resolution: Equatable {
        case durable(String)
        case storageFailure(String)

        public var value: String {
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
    private static let filename = "trackhub_install_uid_v1.txt"

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
        legacyKey: String = "trackhub.install_uid",
        fileURL: URL = defaultFileURL()
    ) -> Resolution {
        lock.lock()
        defer { lock.unlock() }

        let path = fileURL.path
        let legacy = valid(defaults.string(forKey: legacyKey))
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            if let stored = read(fileURL) {
                volatileValues[path] = stored
                defaults.set(stored, forKey: legacyKey)
                return .durable(stored)
            }
            // A valid mirror can safely repair a corrupt/unreadable identity
            // file on the same installation. Never generate and send a new ID
            // merely because durable state became temporarily unavailable.
            if let legacy, persist(legacy, to: fileURL) {
                volatileValues[path] = legacy
                return .durable(legacy)
            }
            let fallback = volatileValues[path] ?? legacy ?? UUID().uuidString
            volatileValues[path] = fallback
            return .storageFailure(fallback)
        }

        // A missing durable file can mean either a 3.0.0–3.0.3 upgrade or an
        // iCloud/device restore. UserDefaults does not let the SDK distinguish
        // those cases safely. Preserve the legacy value so a normal upgrade
        // never creates a phantom second installation; this intentionally
        // retains the pre-3.0.3 restore behavior as well.
        let candidate = legacy ?? volatileValues[path] ?? UUID().uuidString
        volatileValues[path] = candidate
        guard persist(candidate, to: fileURL) else { return .storageFailure(candidate) }
        defaults.set(candidate, forKey: legacyKey)
        return .durable(candidate)
    }

    public static func loadExisting(
        defaults: UserDefaults = .standard,
        legacyKey: String = "trackhub.install_uid",
        fileURL: URL = defaultFileURL()
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let stored = read(fileURL) { return stored }
        return valid(defaults.string(forKey: legacyKey))
    }

    @discardableResult
    public static func retain(
        _ value: String,
        defaults: UserDefaults = .standard,
        legacyKey: String = "trackhub.install_uid",
        fileURL: URL = defaultFileURL()
    ) -> Bool {
        guard let value = valid(value) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard persist(value, to: fileURL) else { return false }
        volatileValues[fileURL.path] = value
        defaults.set(value, forKey: legacyKey)
        return true
    }

    @discardableResult
    public static func remove(
        defaults: UserDefaults = .standard,
        legacyKey: String = "trackhub.install_uid",
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

    private static func valid(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, UUID(uuidString: raw) != nil else { return nil }
        return raw
    }

    private static func read(_ fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 128,
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
            return read(fileURL) == value
        } catch {
            return false
        }
    }
}
