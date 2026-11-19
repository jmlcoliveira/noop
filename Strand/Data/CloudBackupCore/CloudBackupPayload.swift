import Darwin
import Foundation

/// Only an explicit protection choice can omit client encryption. Reading never guesses a mode
/// from a failed decrypt or falls back from a recovery-key backup to an account-protected one.
enum CloudBackupPayload {
    enum Failure: LocalizedError {
        case recoveryKeyRequired

        var errorDescription: String? {
            String(localized: "Enter your recovery code on this iPhone to resume backups.")
        }
    }

    static func prepare(_ compressed: URL, to output: URL, protection: CloudBackupProtection,
                        using key: CloudBackupRecoveryKey?) throws -> CloudBackupEncryption.SealedFile {
        try Task.checkCancellation()
        switch protection {
        case .recoveryKey:
            guard let key else { throw Failure.recoveryKeyRequired }
            return try CloudBackupEncryption.seal(compressed, to: output, using: key)
        case .account:
            try CloudBackupCompression.requireWrapped(compressed)
            return try copyVerified(compressed, to: output)
        }
    }

    /// Authenticate the complete downloaded bytes before any compressed content is decoded.
    /// Account-protected files are verified against the authenticated API's ciphertext-independent
    /// checksum, while recovery-key files additionally authenticate every AES-GCM record.
    static func open(_ input: URL, to output: URL, sha256: String, protection: CloudBackupProtection,
                     using key: CloudBackupRecoveryKey?) throws -> URL {
        try Task.checkCancellation()
        switch protection {
        case .recoveryKey:
            guard let key else { throw Failure.recoveryKeyRequired }
            try CloudBackupEncryption.open(input, to: output, sha256: sha256, using: key)
            return output
        case .account:
            _ = try allowedSize(input)
            guard try CloudBackupEncryption.fileSHA256(input) == sha256 else {
                throw CloudBackupEncryption.Failure.checksumMismatch
            }
            try CloudBackupCompression.requireWrapped(input)
            return input
        }
    }

    private static func allowedSize(_ file: URL) throws -> Int64 {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count > 0 else {
            throw CloudBackupEncryption.Failure.invalidFile
        }
        guard count <= CloudBackupEncryption.maxCiphertextBytes else {
            throw CloudBackupEncryption.Failure.tooLarge
        }
        return Int64(count)
    }

    private static func copyVerified(_ input: URL, to output: URL) throws -> CloudBackupEncryption.SealedFile {
        let expectedSize = try allowedSize(input)
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var copied: Int64 = 0
            while let bytes = try source.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
                try Task.checkCancellation()
                guard Int64(bytes.count) <= expectedSize - copied else {
                    throw CloudBackupEncryption.Failure.invalidFile
                }
                try destination.write(contentsOf: bytes)
                copied += Int64(bytes.count)
            }
            guard copied == expectedSize else { throw CloudBackupEncryption.Failure.invalidFile }
            try destination.synchronize()
            try destination.close()
            let sha256 = try CloudBackupEncryption.fileSHA256(output)
            try Task.checkCancellation()
            return .init(byteCount: copied, sha256: sha256)
        } catch {
            try? destination.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
