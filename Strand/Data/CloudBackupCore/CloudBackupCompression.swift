import Compression
import Darwin
import Foundation

/// Inside the authenticated backup envelope, a stored ZIP is either bare (legacy) or
/// prefixed with an 8-byte magic, version, codec, and big-endian 64-bit expanded size.
enum CloudBackupCompression {
    static let maxExpandedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024 + 2 * 1_024 * 1_024
    private static let maxEncodedBytes = maxExpandedBytes + 1_024 * 1_024
    private static let bufferBytes = 64 * 1_024
    private static let magic = Data("PULSEZIP".utf8)
    private static let version: UInt8 = 1
    private static let lzma: UInt8 = 1
    private static let wrapperBytes: UInt64 = 18
    private static let minimumZIPBytes: UInt64 = 22
    private static let zipSignatures = [Data([0x50, 0x4B, 0x03, 0x04]), Data([0x50, 0x4B, 0x05, 0x06])]

    // Apple's streaming LZMA produces one XZ block with no check, one LZMA2 filter, and an 8 MiB dictionary.
    private static let xzPrefix = Data([
        0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x00, 0xFF, 0x12, 0xD9, 0x41,
        0x02, 0x00, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x74, 0x2F, 0xE5, 0xA3,
    ])
    private static let xzFieldBytes: UInt64 = 12

    enum Failure: LocalizedError {
        case invalidFile
        case unsupportedVersion
        case unsupportedCodec
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidFile: String(localized: "The cloud backup file is incomplete or damaged.")
            case .unsupportedVersion, .unsupportedCodec: String(localized: "Update Pulse to open this cloud backup.")
            case .tooLarge: String(localized: "This backup exceeds the cloud backup size limit.")
            }
        }
    }

    static func compress(_ input: URL, to output: URL) throws {
        try Task.checkCancellation()
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let size = try source.seekToEnd()
        try checkExpandedSize(size)
        try source.seek(toOffset: 0)
        try requireZIP(source)
        try source.seek(toOffset: 0)

        try withNewFile(output) { destination in
            var expandedSize = size.bigEndian
            let header = magic + Data([version, lzma]) + withUnsafeBytes(of: &expandedSize) { Data($0) }
            try destination.write(contentsOf: header)
            let encodedBytes = try transform(source, to: destination, operation: COMPRESSION_STREAM_ENCODE,
                                             inputBytes: size, outputLimit: maxEncodedBytes - wrapperBytes)
            try validateXZ(destination, fileBytes: wrapperBytes + encodedBytes, expandedBytes: size)
        }
    }

    static func expandIfNeeded(_ input: URL, to output: URL) throws -> URL {
        try Task.checkCancellation()
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let size = try source.seekToEnd()
        try source.seek(toOffset: 0)
        if zipSignatures.contains(try readExactly(4, from: source)) {
            try checkExpandedSize(size)
            return input
        }
        guard size <= maxEncodedBytes else { throw Failure.tooLarge }
        try source.seek(toOffset: 0)
        let header = try readExactly(Int(wrapperBytes), from: source)
        guard header.prefix(magic.count) == magic else { throw Failure.invalidFile }
        guard header[8] == version else { throw Failure.unsupportedVersion }
        guard header[9] == lzma else { throw Failure.unsupportedCodec }
        let expandedSize = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        try checkExpandedSize(expandedSize)
        try validateXZ(source, fileBytes: size, expandedBytes: expandedSize)
        try source.seek(toOffset: wrapperBytes)
        try withNewFile(output) { destination in
            let written = try transform(source, to: destination, operation: COMPRESSION_STREAM_DECODE,
                                        inputBytes: size - wrapperBytes, outputLimit: expandedSize)
            guard written == expandedSize else { throw Failure.invalidFile }
            try destination.seek(toOffset: 0)
            try requireZIP(destination)
        }
        return output
    }

    private static func checkExpandedSize(_ size: UInt64) throws {
        guard size >= minimumZIPBytes else { throw Failure.invalidFile }
        guard size <= maxExpandedBytes else { throw Failure.tooLarge }
    }

    private static func requireZIP(_ file: FileHandle) throws {
        guard zipSignatures.contains(try readExactly(4, from: file)) else { throw Failure.invalidFile }
    }

    private static func transform(_ source: FileHandle, to destination: FileHandle,
                                  operation: compression_stream_operation, inputBytes: UInt64,
                                  outputLimit: UInt64) throws -> UInt64 {
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferBytes)
        defer { output.deallocate() }
        var stream = compression_stream(dst_ptr: output, dst_size: 0, src_ptr: UnsafePointer(output), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw Failure.invalidFile
        }
        defer { compression_stream_destroy(&stream) }

        var remaining = inputBytes
        var written: UInt64 = 0
        var ended = false
        while !ended {
            try Task.checkCancellation()
            let input = try readExactly(Int(min(remaining, UInt64(bufferBytes))), from: source)
            remaining -= UInt64(input.count)
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try input.withUnsafeBytes { bytes in
                stream.src_ptr = bytes.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(output)
                stream.src_size = bytes.count
                repeat {
                    try Task.checkCancellation()
                    let available = stream.src_size
                    stream.dst_ptr = output
                    stream.dst_size = bufferBytes
                    let status = compression_stream_process(&stream, flags)
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                        throw Failure.invalidFile
                    }
                    let produced = bufferBytes - stream.dst_size
                    guard UInt64(produced) <= outputLimit - written else { throw Failure.invalidFile }
                    if produced > 0 {
                        try destination.write(contentsOf: Data(bytes: output, count: produced))
                        written += UInt64(produced)
                    }
                    if status == COMPRESSION_STATUS_END {
                        guard remaining == 0, stream.src_size == 0 else { throw Failure.invalidFile }
                        ended = true
                        break
                    }
                    guard produced > 0 || stream.src_size < available else { throw Failure.invalidFile }
                } while stream.src_size > 0 || flags != 0
            }
        }
        guard try source.read(upToCount: 1)?.isEmpty != false else { throw Failure.invalidFile }
        return written
    }

    private static func validateXZ(_ file: FileHandle, fileBytes: UInt64, expandedBytes: UInt64) throws {
        guard fileBytes >= wrapperBytes + UInt64(xzPrefix.count) + 1 + 8 + xzFieldBytes else {
            throw Failure.invalidFile
        }
        try file.seek(toOffset: wrapperBytes)
        guard try readExactly(xzPrefix.count, from: file) == xzPrefix else { throw Failure.invalidFile }

        let footerOffset = fileBytes - xzFieldBytes
        try file.seek(toOffset: footerOffset)
        let footer = try readExactly(Int(xzFieldBytes), from: file)
        guard footer.suffix(4) == Data([0, 0, 0x59, 0x5A]), crc32(footer[4..<10]) == littleEndian32(footer.prefix(4)) else {
            throw Failure.invalidFile
        }
        let indexBytes = (UInt64(littleEndian32(footer[4..<8])) + 1) * 4
        guard (8...24).contains(indexBytes), indexBytes < footerOffset else { throw Failure.invalidFile }
        let indexOffset = footerOffset - indexBytes
        try file.seek(toOffset: indexOffset)
        let index = try readExactly(Int(indexBytes), from: file)
        let contents = index.dropLast(4)
        guard contents.prefix(2) == Data([0, 1]), crc32(contents) == littleEndian32(index.suffix(4)) else {
            throw Failure.invalidFile
        }
        var offset = 2
        let unpadded = try readVLI(contents, offset: &offset)
        let expanded = try readVLI(contents, offset: &offset)
        guard expanded == expandedBytes, unpadded > xzFieldBytes, unpadded <= maxEncodedBytes,
              contents.count - offset <= 3, contents.dropFirst(offset).allSatisfy({ $0 == 0 }) else {
            throw Failure.invalidFile
        }
        let dataEnd = wrapperBytes + xzFieldBytes + unpadded
        let padding = (4 - (unpadded % 4)) % 4
        guard dataEnd + padding == indexOffset else { throw Failure.invalidFile }
        try file.seek(toOffset: dataEnd)
        guard try readExactly(Int(padding), from: file).allSatisfy({ $0 == 0 }) else { throw Failure.invalidFile }

        // An earlier LZMA2 terminator could make the native decoder read a second Block Header.
        // Check each chunk boundary so the verified prefix is the only source of decoder properties.
        var chunks = ChunkReader(file: file, position: wrapperBytes + UInt64(xzPrefix.count), end: dataEnd)
        try validateChunks(&chunks, expandedBytes: expandedBytes)
    }

    private static func validateChunks(_ chunks: inout ChunkReader, expandedBytes: UInt64) throws {
        var expanded: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let control = try chunks.byte()
            if control == 0 {
                guard chunks.position == chunks.end, expanded == expandedBytes else { throw Failure.invalidFile }
                return
            }
            guard control == 1 || control == 2 || control >= 0x80 else { throw Failure.invalidFile }
            let lowSize = try chunks.bigEndian16()
            let rawSize = (UInt64(control >= 0x80 ? control & 0x1F : 0) << 16) + lowSize + 1
            guard rawSize <= expandedBytes - expanded else { throw Failure.invalidFile }
            expanded += rawSize
            let compressedSize = control >= 0x80 ? try chunks.bigEndian16() + 1 : rawSize
            if control >= 0xC0 {
                let properties = Int(try chunks.byte())
                let lc = properties % 9
                let lp = (properties / 9) % 5
                let pb = properties / (9 * 5)
                guard lc + lp <= 4, pb <= 4 else { throw Failure.invalidFile }
            }
            try chunks.skip(compressedSize)
        }
    }

    private struct ChunkReader {
        let file: FileHandle
        var position: UInt64
        let end: UInt64
        private var buffer = Data()
        private var bufferStart: UInt64 = 0

        init(file: FileHandle, position: UInt64, end: UInt64) {
            self.file = file
            self.position = position
            self.end = end
        }

        mutating func byte() throws -> UInt8 {
            guard position < end else { throw Failure.invalidFile }
            if position >= bufferStart + UInt64(buffer.count) {
                try file.seek(toOffset: position)
                buffer = try readExactly(Int(min(end - position, UInt64(bufferBytes))), from: file)
                bufferStart = position
            }
            let value = buffer[Int(position - bufferStart)]
            position += 1
            return value
        }

        mutating func bigEndian16() throws -> UInt64 {
            let high = UInt64(try byte())
            return (high << 8) | UInt64(try byte())
        }

        mutating func skip(_ count: UInt64) throws {
            guard count <= end - position else { throw Failure.invalidFile }
            position += count
        }
    }

    private static func readVLI(_ contents: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<9 {
            guard offset < contents.endIndex else { throw Failure.invalidFile }
            let byte = contents[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 {
                guard index == 0 || byte != 0 else { throw Failure.invalidFile }
                return result
            }
        }
        throw Failure.invalidFile
    }

    private static func littleEndian32(_ bytes: Data) -> UInt32 {
        bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320) }
        }
        return ~crc
    }

    private static func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let bytes = try file.read(upToCount: count - result.count), !bytes.isEmpty else {
                throw Failure.invalidFile
            }
            result.append(bytes)
        }
        return result
    }

    private static func withNewFile(_ output: URL, _ body: (FileHandle) throws -> Void) throws {
        let descriptor = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try body(handle)
            try Task.checkCancellation()
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
