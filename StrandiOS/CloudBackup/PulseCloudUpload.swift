import CryptoKit
import Foundation

struct PulseCloudPendingUpload: Codable, Sendable {
    static let directLimit: Int64 = 80 * 1_024 * 1_024
    static let partSize: Int64 = 16 * 1_024 * 1_024
    static let maxParts = 32
    private static let fileAttributes: [FileAttributeKey: any Sendable] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        .posixPermissions: 0o600
    ]

    struct Part: Codable, Sendable {
        let number: Int
        let size: Int64
        let sha256: String
    }

    let id: String
    let generation: Int
    let size: Int64
    let sha256: String
    let fingerprint: String
    var storedProtection: CloudBackupProtection?
    // Earlier installations stored only the five fields above for a direct PUT.
    var parts: [Part]?
    var receivedParts: Set<Int>?

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("PulseCloudUploads", isDirectory: true)
    }

    var fileURL: URL { Self.directory.appendingPathComponent(id + ".pulsebackup") }
    private var partsDirectory: URL { Self.directory.appendingPathComponent(id + ".parts", isDirectory: true) }
    var completionFile: URL { partsDirectory.appendingPathComponent("complete") }
    var isMultipart: Bool { parts != nil }
    var protection: CloudBackupProtection { storedProtection ?? .recoveryKey }
    var allPartsReceived: Bool { parts?.count == receivedParts?.count && isMultipart }

    func file(for number: Int) -> URL { partsDirectory.appendingPathComponent(String(number)) }

    var retainedFilesExist: Bool {
        let files = FileManager.default
        guard let parts else { return files.fileExists(atPath: fileURL.path) }
        return files.fileExists(atPath: completionFile.path) &&
            parts.allSatisfy { files.fileExists(atPath: file(for: $0.number).path) }
    }

    mutating func accept(_ status: PulseCloudMultipartStatus) throws {
        guard let parts, status.partSize == Self.partSize, status.totalParts == parts.count,
              status.receivedParts.count == Set(status.receivedParts).count,
              Set(status.receivedParts).isSubset(of: Set(parts.map(\.number))) else {
            throw PulseCloudAPIError.invalidResponse
        }
        receivedParts = Set(status.receivedParts)
    }

    func matches(_ backup: PulseCloudBackup) -> Bool {
        backup.id == id && backup.sha256 == sha256 && backup.size == size && backup.protection == protection
    }

    mutating func retain(file: URL) throws {
        var directory = Self.directory
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        do {
            if size <= Self.directLimit {
                try files.moveItem(at: file, to: fileURL)
                try files.setAttributes(Self.fileAttributes, ofItemAtPath: fileURL.path)
            } else {
                guard size <= Self.partSize * Int64(Self.maxParts) else { throw PulseCloudAPIError.tooLarge }
                try files.createDirectory(at: partsDirectory, withIntermediateDirectories: false,
                                          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                       .posixPermissions: 0o700])
                parts = try Self.split(file, size: size, sha256: sha256, into: partsDirectory)
                receivedParts = []
                try Self.createProtectedFile(completionFile)
            }
        } catch {
            discard()
            throw error
        }
    }

    static func split(_ fileURL: URL, size: Int64, sha256: String, into directory: URL) throws -> [Part] {
        guard size > 0, size <= partSize * Int64(maxParts) else { throw PulseCloudAPIError.tooLarge }
        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        var digest = SHA256()
        var remaining = size
        var parts: [Part] = []
        while remaining > 0 {
            let bytes = min(Self.partSize, remaining)
            let url = directory.appendingPathComponent(String(parts.count))
            let part = try Self.writePart(parts.count, to: url, size: bytes, reading: source, digest: &digest)
            parts.append(part)
            remaining -= bytes
        }
        guard try source.read(upToCount: 1)?.isEmpty != false,
              CloudBackupEncryption.hex(digest.finalize()) == sha256 else {
            throw CloudBackupEncryption.Failure.invalidFile
        }
        return parts
    }

    private static func writePart(_ number: Int, to url: URL, size: Int64, reading source: FileHandle,
                                  digest: inout SHA256) throws -> Part {
        try createProtectedFile(url)
        let target = try FileHandle(forWritingTo: url)
        defer { try? target.close() }
        var partDigest = SHA256()
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, 1_024 * 1_024))
            guard let data = try source.read(upToCount: count), !data.isEmpty else {
                throw CloudBackupEncryption.Failure.invalidFile
            }
            try target.write(contentsOf: data)
            partDigest.update(data: data)
            digest.update(data: data)
            remaining -= Int64(data.count)
        }
        try target.synchronize()
        try target.close()
        return Part(number: number, size: size, sha256: CloudBackupEncryption.hex(partDigest.finalize()))
    }

    private static func createProtectedFile(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: Self.fileAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: isMultipart ? partsDirectory : fileURL)
        // Splitting can fail before parts is assigned.
        if !isMultipart { try? FileManager.default.removeItem(at: partsDirectory) }
    }

    static func cleanOrphans(keeping pendingID: String?) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.deletingPathExtension().lastPathComponent != pendingID {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct PulseCloudUploadTask: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case direct
        case part(Int)
        case complete
    }

    let backupID: String
    let kind: Kind

    var description: String {
        switch kind {
        case .direct: backupID
        case .part(let number): "\(backupID):\(number)"
        case .complete: "\(backupID):complete"
        }
    }

    init(backupID: String, kind: Kind) {
        self.backupID = backupID
        self.kind = kind
    }

    init?(description: String?, url: URL?) {
        if let description {
            let pieces = description.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = pieces.first, UUID(uuidString: String(first)) != nil else { return nil }
            let id = String(first)
            if pieces.count == 1 {
                self.init(backupID: id, kind: .direct)
            } else if pieces.count == 2, pieces[1] == "complete" {
                self.init(backupID: id, kind: .complete)
            } else if pieces.count == 2, let number = Self.partNumber(pieces[1]) {
                self.init(backupID: id, kind: .part(number))
            } else {
                return nil
            }
            return
        }
        guard let url, url.scheme == "https", url.host == "pulse.joliveira.xyz",
              url.pathComponents.starts(with: ["/", "v1", "backups"]) else { return nil }
        let path = url.pathComponents
        guard path.count >= 4,
              UUID(uuidString: path[3]) != nil else { return nil }
        if path.count == 4 {
            self.init(backupID: path[3], kind: .direct)
        } else if path.count == 6, path[4] == "parts", path[5] == "complete" {
            self.init(backupID: path[3], kind: .complete)
        } else if path.count == 6, path[4] == "parts", let number = Self.partNumber(path[5]) {
            self.init(backupID: path[3], kind: .part(number))
        } else {
            return nil
        }
    }

    private static func partNumber(_ value: some StringProtocol) -> Int? {
        guard let number = Int(value), (0..<PulseCloudPendingUpload.maxParts).contains(number),
              String(number) == value else { return nil }
        return number
    }
}
