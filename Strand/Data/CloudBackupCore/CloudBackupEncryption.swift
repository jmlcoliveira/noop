import CryptoKit
import Foundation

struct CloudBackupRecoveryKey: Equatable, Sendable {
    private static let prefix = "PULSE1-"
    fileprivate let bytes: Data

    static func generate() -> Self {
        let key = SymmetricKey(size: .bits256)
        return Self(bytes: key.withUnsafeBytes { Data($0) })
    }

    init(code: String) throws {
        let compact = code.filter { !$0.isWhitespace }
        guard compact.hasPrefix(Self.prefix) else { throw CloudBackupEncryption.Failure.invalidRecoveryCode }
        let body = compact.dropFirst(Self.prefix.count)
        guard body.utf8.count == 43,
              let bytes = Data(base64Encoded: body.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32 else { throw CloudBackupEncryption.Failure.invalidRecoveryCode }
        self.init(bytes: bytes)
        guard self.code == compact else { throw CloudBackupEncryption.Failure.invalidRecoveryCode }
    }

    private init(bytes: Data) {
        self.bytes = bytes
    }

    var code: String {
        Self.prefix + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The v1 file is a header followed by consecutive AES-256-GCM ciphertext and tag pairs.
/// Header fields are the 8-byte magic, 1-byte version, 32-byte HKDF salt, and big-endian
/// 8-byte plaintext size. Each chunk is up to 1 MiB and has a 16-byte tag. Its nonce is
/// four zero bytes and the big-endian 8-byte chunk index, starting at zero. A new
/// per-file key is derived from the recovery key and a fresh salt. The complete header
/// and chunk index are authenticated for every chunk.
enum CloudBackupEncryption {
    static let maxCiphertextBytes: Int64 = 512 * 1_024 * 1_024
    private static let magic = Data([0x50, 0x55, 0x4C, 0x53, 0x45, 0x43, 0x42, 0x00])
    private static let version: UInt8 = 1
    private static let saltBytes = 32
    private static let headerBytes = 49
    private static let chunkBytes = 1_024 * 1_024
    private static let tagBytes = 16

    struct SealedFile: Sendable {
        let byteCount: Int64
        let sha256: String
    }

    enum Failure: LocalizedError {
        case invalidRecoveryCode
        case tooLarge
        case invalidFile
        case unsupportedVersion
        case checksumMismatch
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .invalidRecoveryCode: String(localized: "Enter the complete Pulse recovery key.")
            case .tooLarge: String(localized: "This backup exceeds the 512 MB cloud backup limit.")
            case .invalidFile: String(localized: "The cloud backup file is incomplete or damaged.")
            case .unsupportedVersion: String(localized: "Update Pulse to open this cloud backup.")
            case .checksumMismatch: String(localized: "The downloaded cloud backup failed its checksum.")
            case .authenticationFailed: String(localized: "The recovery key could not unlock this cloud backup.")
            }
        }
    }

    static func seal(_ input: URL, to output: URL, using recoveryKey: CloudBackupRecoveryKey) throws -> SealedFile {
        let plaintextBytes = try fileSize(input)
        guard plaintextBytes > 0 else { throw Failure.invalidFile }
        guard plaintextBytes <= maxCiphertextBytes,
              sealedSize(plaintextBytes) <= maxCiphertextBytes else { throw Failure.tooLarge }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let header = magic + Data([version]) + salt + encoded(UInt64(plaintextBytes))
        let key = fileKey(recoveryKey, salt: salt)
        return try transform(input, to: output) { source, destination in
            var digest = SHA256()
            try destination.write(contentsOf: header)
            digest.update(data: header)
            var remaining = plaintextBytes
            var index: UInt64 = 0
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(Int64(chunkBytes), remaining))
                let plaintext = try readExactly(count, from: source)
                let position = encoded(index)
                let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce(position),
                                              authenticating: header + position)
                try destination.write(contentsOf: sealed.ciphertext)
                try destination.write(contentsOf: sealed.tag)
                digest.update(data: sealed.ciphertext)
                digest.update(data: sealed.tag)
                remaining -= Int64(count)
                index += 1
            }
            try requireEOF(source)
            return SealedFile(byteCount: sealedSize(plaintextBytes), sha256: hex(digest.finalize()))
        }
    }

    static func open(_ input: URL, to output: URL, sha256: String,
                     using recoveryKey: CloudBackupRecoveryKey) throws {
        let ciphertextBytes = try fileSize(input)
        guard ciphertextBytes <= maxCiphertextBytes else { throw Failure.tooLarge }
        try transform(input, to: output) { source, destination in
            let header = try readExactly(headerBytes, from: source)
            guard header.prefix(magic.count) == magic else { throw Failure.invalidFile }
            guard header[magic.count] == version else { throw Failure.unsupportedVersion }

            let saltStart = magic.count + 1
            let salt = header.subdata(in: saltStart..<(saltStart + saltBytes))
            let size = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size > 0, size <= UInt64(maxCiphertextBytes),
                  sealedSize(Int64(size)) == ciphertextBytes else { throw Failure.invalidFile }
            let key = fileKey(recoveryKey, salt: salt)
            var digest = SHA256()
            digest.update(data: header)
            var remaining = Int64(size)
            var index: UInt64 = 0
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(Int64(chunkBytes), remaining))
                let ciphertext = try readExactly(count, from: source)
                let tag = try readExactly(tagBytes, from: source)
                digest.update(data: ciphertext)
                digest.update(data: tag)
                let position = encoded(index)
                let plaintext: Data
                do {
                    let box = try AES.GCM.SealedBox(nonce: nonce(position), ciphertext: ciphertext, tag: tag)
                    plaintext = try AES.GCM.open(box, using: key, authenticating: header + position)
                } catch {
                    throw Failure.authenticationFailed
                }
                try destination.write(contentsOf: plaintext)
                remaining -= Int64(count)
                index += 1
            }
            try requireEOF(source)
            guard hex(digest.finalize()) == sha256 else { throw Failure.checksumMismatch }
        }
    }

    static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: chunkBytes), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return hex(digest.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw Failure.invalidFile }
        return size
    }

    private static func sealedSize(_ plaintextBytes: Int64) -> Int64 {
        let chunks = (plaintextBytes + Int64(chunkBytes) - 1) / Int64(chunkBytes)
        return Int64(headerBytes) + plaintextBytes + chunks * Int64(tagBytes)
    }

    private static func fileKey(_ recoveryKey: CloudBackupRecoveryKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey.bytes),
                               salt: salt, info: Data("PulseCloudBackup v1".utf8), outputByteCount: 32)
    }

    private static func encoded(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func nonce(_ position: Data) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + position)
    }

    private static func readExactly(_ count: Int, from source: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try source.read(upToCount: count - data.count), !next.isEmpty else {
                throw Failure.invalidFile
            }
            data.append(next)
        }
        return data
    }

    private static func requireEOF(_ source: FileHandle) throws {
        guard try source.read(upToCount: 1)?.isEmpty != false else { throw Failure.invalidFile }
    }

    private static func transform<T>(_ input: URL, to output: URL,
                                     _ body: (FileHandle, FileHandle) throws -> T) throws -> T {
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let destination = try FileHandle(forWritingTo: output)
            defer { try? destination.close() }
            let result = try body(source, destination)
            try destination.synchronize()
            try destination.close()
            return result
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }
}
