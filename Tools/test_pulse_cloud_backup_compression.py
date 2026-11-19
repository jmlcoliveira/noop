"""Exercise the production Pulse compression wrapper with Apple's streaming codec."""

from __future__ import annotations

import lzma
from pathlib import Path
import random
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Strand" / "Data" / "CloudBackupCore" / "CloudBackupCompression.swift"
SWIFTC = shutil.which("swiftc")
WRAPPER_BYTES = 18
XZ_PREFIX_BYTES = 24
MAX_EXPANDED_BYTES = 2 * 1024**3 + 8 * 1024**2
HARNESS = r"""
import Foundation

@main
struct Harness {
    static func main() async {
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        do {
            switch CommandLine.arguments[1] {
            case "compress":
                try CloudBackupCompression.compress(input, to: output)
                print("compressed")
            case "expand":
                let result = try CloudBackupCompression.expandIfNeeded(input, to: output)
                print(result == input ? "legacy" : "expanded")
            case "cancel":
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try CloudBackupCompression.compress(input, to: output)
                }
                try await task.value
                print("not cancelled")
            default:
                preconditionFailure("unknown test command")
            }
        } catch is CancellationError {
            print("cancelled")
        } catch {
            print(String(describing: error))
        }
    }
}
"""


def crc32(data: bytes) -> bytes:
    return zlib.crc32(data).to_bytes(4, "little")


def vli(number: int) -> bytes:
    result = bytearray()
    while number >= 128:
        result.append((number & 127) | 128)
        number >>= 7
    result.append(number)
    return bytes(result)


def wrapper_with_block(template: bytes, body: bytes, expanded: int) -> bytes:
    block_bytes = 12 + len(body)
    index = b"\0\1" + vli(block_bytes) + vli(expanded)
    index += bytes((-len(index)) % 4)
    index += crc32(index)
    footer = (len(index) // 4 - 1).to_bytes(4, "little") + b"\0\0"
    header = template[:10] + expanded.to_bytes(8, "big")
    prefix = template[WRAPPER_BYTES:WRAPPER_BYTES + XZ_PREFIX_BYTES]
    return header + prefix + body + bytes((-block_bytes) % 4) + index + crc32(footer) + footer + b"YZ"


@unittest.skipUnless(sys.platform == "darwin" and SWIFTC, "Requires Apple's Swift Compression framework")
class PulseCloudBackupCompressionTests(unittest.TestCase):
    def test_production_wrapper_round_trip_and_rejection(self):
        with tempfile.TemporaryDirectory(prefix="pulse-compression-test-") as temporary:
            directory = Path(temporary)
            main = directory / "Harness.swift"
            executable = directory / "compression-test"
            main.write_text(HARNESS, encoding="utf-8")
            subprocess.run(
                [SWIFTC, "-O", "-module-cache-path", str(directory / "module-cache"),
                 str(HELPER), str(main), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=180,
            )

            def run(operation, source, destination):
                return subprocess.run(
                    [str(executable), operation, str(source), str(destination)],
                    check=True, capture_output=True, text=True, timeout=45,
                ).stdout.strip()

            fixture_data = random.Random(1926).randbytes(768 * 1024 + 51)
            for label, contents in (("random", fixture_data), ("mostly-zero", b"restorable" + bytes(1024**2 + 7))):
                with self.subTest(payload=label):
                    source = directory / f"{label}.zip"
                    compressed = directory / f"{label}.wrapped"
                    restored = directory / f"{label}-restored.zip"
                    with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
                        archive.writestr("snapshot.sqlite", contents)
                    self.assertEqual(run("compress", source, compressed), "compressed")
                    encoded = compressed.read_bytes()
                    self.assertEqual(encoded[:10], b"PULSEZIP\x01\x01")
                    self.assertEqual(int.from_bytes(encoded[10:WRAPPER_BYTES], "big"), source.stat().st_size)
                    self.assertEqual(lzma.decompress(encoded[WRAPPER_BYTES:]), source.read_bytes())
                    self.assertEqual(run("expand", compressed, restored), "expanded")
                    self.assertEqual(restored.read_bytes(), source.read_bytes())
                    self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o600)
                    if label == "random":
                        self.assertGreater(len(encoded), 2 * 64 * 1024)
                    else:
                        self.assertLess(len(encoded), len(contents) // 8)

            legacy = directory / "random.zip"
            stored = directory / "existing.zip"
            stored.write_bytes(b"keep this file")
            self.assertEqual(run("expand", legacy, stored), "legacy")
            self.assertEqual(stored.read_bytes(), b"keep this file")
            self.assertNotEqual(run("compress", legacy, stored), "compressed")
            self.assertEqual(stored.read_bytes(), b"keep this file")

            valid = (directory / "random.wrapped").read_bytes()
            expanded = int.from_bytes(valid[10:WRAPPER_BYTES], "big")
            header = valid[:WRAPPER_BYTES]
            payload = valid[WRAPPER_BYTES:]
            oversized = valid[:10] + (MAX_EXPANDED_BYTES + 1).to_bytes(8, "big") + payload
            wrong_length = valid[:10] + (expanded - 1).to_bytes(8, "big") + payload

            block_header = bytearray(payload[12:24])
            block_header[4] = 0x28  # Valid XZ encoding for a dictionary near 4 GiB.
            block_header[8:12] = crc32(block_header[:8])
            large_dictionary = header + payload[:12] + block_header + payload[24:]
            index_size = (int.from_bytes(payload[-8:-4], "little") + 1) * 4
            original_chunks = payload[XZ_PREFIX_BYTES:-(12 + index_size)]
            hidden_second_block = wrapper_with_block(valid, original_chunks + block_header + b"\0", expanded)

            non_zip = b"a structurally valid non-ZIP file"
            non_zip_block = b"\x01" + (len(non_zip) - 1).to_bytes(2, "big") + non_zip + b"\0"
            invalid_range_stream = b"\xe0\x00\x15\x00\x00\x5d\xff\x00"
            invalid = [
                ("unknown", b"NOTAZIP!" + valid[8:], "invalidFile"),
                ("version", valid[:8] + b"\x02" + valid[9:], "unsupportedVersion"),
                ("codec", valid[:9] + b"\x02" + valid[10:], "unsupportedCodec"),
                ("expanded-cap", oversized, "tooLarge"),
                ("expanded-size", wrong_length, "invalidFile"),
                ("truncated", valid[:-1], "invalidFile"),
                ("trailing", valid + b"\0", "invalidFile"),
                ("stream-padding", valid + bytes(4), "invalidFile"),
                ("concatenated", valid + payload, "invalidFile"),
                ("dictionary", large_dictionary, "invalidFile"),
                ("second-block", hidden_second_block, "invalidFile"),
                ("non-zip", wrapper_with_block(valid, non_zip_block, len(non_zip)), "invalidFile"),
                ("bad-range-stream", wrapper_with_block(valid, invalid_range_stream, 22), "invalidFile"),
            ]
            output = directory / "must-not-exist"
            for label, bytes_, expected in invalid:
                with self.subTest(malformed=label):
                    source = directory / f"{label}.bad"
                    source.write_bytes(bytes_)
                    self.assertEqual(run("expand", source, output), expected)
                    self.assertFalse(output.exists(), "a rejected frame must leave no decoded ZIP")

            sparse = directory / "oversized.zip"
            with sparse.open("wb") as stream:
                stream.write(b"PK\x03\x04")
                stream.truncate(MAX_EXPANDED_BYTES + 1)
            self.assertEqual(run("compress", sparse, output), "tooLarge")
            self.assertEqual(run("expand", sparse, output), "tooLarge")
            self.assertEqual(run("cancel", legacy, output), "cancelled")
            self.assertFalse(output.exists())
