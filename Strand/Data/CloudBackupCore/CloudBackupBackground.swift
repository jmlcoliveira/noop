import CoreFoundation
import Foundation
import ImageIO

/// The active custom background is portable. Recent-photo filenames identify files on one device.
struct CloudBackupBackground {
    static let field = "background"
    private static let maxBytes = 3 * 1024 * 1024
    private static let maxPixelsPerEdge = 2560
    private static let enabledKey = "noop.backgroundImageEnabled"
    private static let modeKey = "noop.backgroundFillMode"
    private static let recentsKey = "noop.backgroundRecents"
    private static let presentKey = "noop.backgroundImagePresent"
    private static let legacyFile = "background.jpg"
    private static let fillModes: Set<String> = ["fill", "fit", "stretch", "tile"]

    let enabled: Bool
    let fillMode: String
    let image: Data?

    enum Failure: LocalizedError {
        case photoTooLarge
        case unreadablePhoto

        var errorDescription: String? {
            switch self {
            case .photoTooLarge: String(localized: "The selected background photo exceeds the 3 MiB backup limit.")
            case .unreadablePhoto: String(localized: "Pulse couldn’t read the selected background photo for backup.")
            }
        }
    }

    struct Prepared {
        let enabled: Bool
        let fillMode: String
        let filename: String?

        func apply(to defaults: UserDefaults) {
            defaults.set(filename.map { "\($0),\(fillMode)" } ?? "", forKey: CloudBackupBackground.recentsKey)
            defaults.set(filename != nil, forKey: CloudBackupBackground.presentKey)
            defaults.set(fillMode, forKey: CloudBackupBackground.modeKey)
            defaults.set(enabled, forKey: CloudBackupBackground.enabledKey)
        }
    }

    static func snapshot(from defaults: UserDefaults, backgroundsAt directory: URL? = nil) throws -> Self {
        let directory = try directory ?? Self.directory(create: false)
        let enabled = defaults.bool(forKey: enabledKey)
        let storedMode = resolvedMode(defaults.string(forKey: modeKey))
        let recents = (defaults.string(forKey: recentsKey) ?? "").split(separator: ";")
        for recent in recents {
            let parts = recent.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let filename = String(parts[0])
            guard safeFilename(filename),
                  let image = try readPhoto(directory.appendingPathComponent(filename)) else { continue }
            return Self(enabled: enabled, fillMode: resolvedMode(String(parts[1])), image: image)
        }
        if defaults.bool(forKey: presentKey), let image = try readPhoto(directory.appendingPathComponent(legacyFile)) {
            return Self(enabled: enabled, fillMode: storedMode, image: image)
        }
        return Self(enabled: enabled, fillMode: storedMode, image: nil)
    }

    var json: [String: Any] {
        ["enabled": enabled, "fillMode": fillMode, "image": image.map { $0.base64EncodedString() as Any } ?? NSNull()]
    }

    static func decode(_ raw: Any) throws -> Self {
        let corrupt = CocoaError(.fileReadCorruptFile)
        guard let object = raw as? [String: Any],
              let enabled = object["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(),
              let mode = object["fillMode"] as? String, fillModes.contains(mode),
              let encoded = object["image"] else { throw corrupt }
        if encoded is NSNull { return Self(enabled: enabled.boolValue, fillMode: mode, image: nil) }
        guard let base64 = encoded as? String, base64.utf8.count <= ((maxBytes + 2) / 3) * 4,
              let image = Data(base64Encoded: base64), image.count <= maxBytes,
              validImage(image) else { throw corrupt }
        return Self(enabled: enabled.boolValue, fillMode: mode, image: image)
    }

    /// Stage a fresh filename so a write failure leaves the current photo and defaults intact.
    /// BackgroundImageStore reclaims unreferenced bg-* files on initialization.
    func prepareRestore(backgroundsAt directory: URL? = nil) throws -> Prepared {
        guard let image else { return Prepared(enabled: enabled, fillMode: fillMode, filename: nil) }
        let directory = try directory ?? Self.directory(create: true)
        let filename = "bg-cloud-\(UUID().uuidString).jpg"
        try image.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return Prepared(enabled: enabled, fillMode: fillMode, filename: filename)
    }

    private static func resolvedMode(_ raw: String?) -> String {
        guard let raw, fillModes.contains(raw) else { return "fill" }
        return raw
    }

    private static func directory(create: Bool) throws -> URL {
        // Matches BackgroundImageStore.dirURL(create:).
        let fm = FileManager.default
        let url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: create)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        if create { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    private static func safeFilename(_ name: String) -> Bool {
        if name == legacyFile { return true }
        if name.hasPrefix("bg-cloud-"), name.hasSuffix(".jpg") {
            return UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil
        }
        guard name.hasPrefix("bg-"), name.hasSuffix(".jpg") else { return false }
        let stamp = name.dropFirst(3).dropLast(4)
        return !stamp.isEmpty && stamp.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func readPhoto(_ url: URL) throws -> Data? {
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Failure.unreadablePhoto }
            guard (info.fileSize ?? 0) <= maxBytes else { throw Failure.photoTooLarge }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else { throw Failure.photoTooLarge }
            guard validImage(data) else { throw Failure.unreadablePhoto }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private static func validImage(_ image: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxPixelsPerEdge).contains(width), (1...maxPixelsPerEdge).contains(height) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
