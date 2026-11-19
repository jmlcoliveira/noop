import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc")
HARNESS = r"""
import CryptoKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let input = directory.appendingPathComponent("encrypted.pulsebackup")
let files = FileManager.default
precondition(files.createFile(atPath: input.path, contents: nil))
let out = try FileHandle(forWritingTo: input)
let megabyte = Data(repeating: 0x51, count: 1_024 * 1_024)
var firstDigest = SHA256()
for _ in 0..<16 {
    try out.write(contentsOf: megabyte)
    firstDigest.update(data: megabyte)
}
let tail = Data([0x72, 0xaf, 0x06])
try out.write(contentsOf: tail)
try out.close()
let sha = try CloudBackupEncryption.fileSHA256(input)
let splitDirectory = directory.appendingPathComponent("parts")
try files.createDirectory(at: splitDirectory, withIntermediateDirectories: true)
let size = PulseCloudPendingUpload.partSize + Int64(tail.count)
let parts = try PulseCloudPendingUpload.split(input, size: size, sha256: sha, into: splitDirectory)
precondition(parts.map(\.number) == [0, 1])
precondition(parts.map(\.size) == [PulseCloudPendingUpload.partSize, Int64(tail.count)])
precondition(parts.map(\.sha256) == [
    CloudBackupEncryption.hex(firstDigest.finalize()), CloudBackupEncryption.hex(SHA256.hash(data: tail))
])
let partHash = try CloudBackupEncryption.fileSHA256(splitDirectory.appendingPathComponent("0"))
let lastPart = try Data(contentsOf: splitDirectory.appendingPathComponent("1"))
precondition(partHash == parts[0].sha256 && lastPart == tail)

let invalidDirectory = directory.appendingPathComponent("invalid")
try files.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
do {
    _ = try PulseCloudPendingUpload.split(input, size: size, sha256: String(repeating: "0", count: 64),
                                          into: invalidDirectory)
    fatalError("Must reject a changed ciphertext")
} catch CloudBackupEncryption.Failure.invalidFile {}

let id = "99c53e6e-1647-4d0f-a9e0-839530f7bfe4"
let original = #"{"id":"99c53e6e-1647-4d0f-a9e0-839530f7bfe4","generation":4,"size":42,"sha256":"old","fingerprint":"old"}"#
let direct = try JSONDecoder().decode(PulseCloudPendingUpload.self, from: Data(original.utf8))
precondition(!direct.isMultipart && !direct.allPartsReceived && direct.protection == .recoveryKey)
var multipart = PulseCloudPendingUpload(id: id, generation: 4, size: size, sha256: sha, fingerprint: "test",
                                        parts: parts, receivedParts: [])
try multipart.accept(PulseCloudMultipartStatus(partSize: PulseCloudPendingUpload.partSize, totalParts: 2,
                                              receivedParts: [1], backup: nil))
precondition(multipart.receivedParts == [1] && !multipart.allPartsReceived)
let reloaded = try JSONDecoder().decode(PulseCloudPendingUpload.self, from: JSONEncoder().encode(multipart))
precondition(reloaded.receivedParts == [1] && reloaded.isMultipart)
for invalid in [[2], [1, 1]] {
    do {
        try multipart.accept(PulseCloudMultipartStatus(partSize: PulseCloudPendingUpload.partSize, totalParts: 2,
                                                       receivedParts: invalid, backup: nil))
        fatalError("Must reject invalid server part indexes")
    } catch PulseCloudAPIError.invalidResponse {}
}
try multipart.accept(PulseCloudMultipartStatus(partSize: PulseCloudPendingUpload.partSize, totalParts: 2,
                                              receivedParts: [1, 0], backup: nil))
precondition(multipart.allPartsReceived)

let api = PulseCloudAPI()
let device = PulseCloudDevice(id: "phone", key: "device-key")
let legacyRequest = api.uploadRequest(direct, device: device, token: "firebase-token")
precondition(legacyRequest.value(forHTTPHeaderField: "X-Pulse-Backup-Protection") == "recoveryKey")
multipart.storedProtection = .account
let accountRequest = api.uploadRequest(multipart, device: device, token: "firebase-token")
precondition(accountRequest.value(forHTTPHeaderField: "X-Pulse-Backup-Protection") == "account")
let startRequest = try api.multipartStartRequest(multipart, device: device, token: "firebase-token")
let manifest = try JSONSerialization.jsonObject(with: startRequest.httpBody!) as! [String: Any]
precondition(startRequest.httpMethod == "POST" && startRequest.url?.path == "/v1/backups/\(id)/parts")
precondition(manifest["sha256"] as? String == sha && manifest["size"] as? Int64 == size)
precondition(manifest["protection"] as? String == "account")

func backupResponse(protection: Any? = nil) throws -> PulseCloudBackup {
    let response = HTTPURLResponse(url: legacyRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    var record: [String: Any] = ["id": id, "size": size, "sha256": sha, "createdAt": "2026-11-19T12:00:00Z"]
    if let protection { record["protection"] = protection }
    return try PulseCloudAPI.backupResponse(response, body: JSONSerialization.data(withJSONObject: record))
}
let legacyBackup = try backupResponse()
let accountBackup = try backupResponse(protection: "account")
precondition(legacyBackup.protection == .recoveryKey && !multipart.matches(legacyBackup))
precondition(accountBackup.protection == .account && multipart.matches(accountBackup))
let legacyState = PulseCloudState(activeDeviceId: nil, generation: 0, backups: [], maxBackupBytes: 80)
precondition(legacyState.supports(.recoveryKey) && !legacyState.supports(.account))
let modernState = PulseCloudState(activeDeviceId: nil, generation: 0, backups: [], maxBackupBytes: 512,
                                  supportedBackupProtections: ["recoveryKey", "account", "futureMode"])
precondition(modernState.supports(.recoveryKey) && modernState.supports(.account))
for unsupported in ["other", NSNull()] as [Any] {
    do {
        _ = try backupResponse(protection: unsupported)
        fatalError("Unexpected protection must never be accepted")
    } catch is DecodingError {}
}
let upload = api.partRequest(parts[1], upload: multipart, device: device, token: "firebase-token")
precondition(upload.httpMethod == "PUT")
precondition(upload.value(forHTTPHeaderField: "Content-Length") == "3")
precondition(upload.value(forHTTPHeaderField: "X-Pulse-SHA256") == parts[1].sha256)
precondition(upload.value(forHTTPHeaderField: "X-Pulse-Generation") == "4")
precondition(upload.value(forHTTPHeaderField: "X-Pulse-Device-ID") == "phone")
precondition(upload.value(forHTTPHeaderField: "X-Pulse-Device-Key") == "device-key")
precondition(upload.value(forHTTPHeaderField: "Authorization") == "Bearer firebase-token")
precondition(upload.url?.path == "/v1/backups/\(id)/parts/1")
let complete = api.completeMultipartRequest(multipart, device: device, token: "firebase-token")
precondition(complete.httpMethod == "POST" && complete.url?.path == "/v1/backups/\(id)/parts/complete")

let oldTask = PulseCloudUploadTask(backupID: id, kind: .direct)
precondition(PulseCloudUploadTask(description: oldTask.description, url: nil) == oldTask)
let partTask = PulseCloudUploadTask(backupID: id, kind: .part(1))
precondition(PulseCloudUploadTask(description: partTask.description, url: nil) == partTask)
precondition(PulseCloudUploadTask(description: nil, url: upload.url) == partTask)
let completion = PulseCloudUploadTask(backupID: id, kind: .complete)
precondition(PulseCloudUploadTask(description: completion.description, url: nil) == completion)
precondition(PulseCloudUploadTask(description: nil, url: complete.url) == completion)
precondition(PulseCloudUploadTask(description: id + ":32", url: nil) == nil)
precondition(PulseCloudUploadTask(description: id + ":01", url: nil) == nil)
let foreign = URL(string: "https://example.test/v1/backups/\(id)/parts/1")
precondition(PulseCloudUploadTask(description: nil, url: foreign) == nil)
"""


@unittest.skipUnless(SWIFTC and sys.platform == "darwin", "Requires Apple Swift and CryptoKit")
class PulseCloudUploadTests(unittest.TestCase):
    def test_split_retained_progress_and_background_request_identity(self):
        with tempfile.TemporaryDirectory(prefix="pulse-cloud-upload-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(HARNESS, encoding="utf-8")
            executable = directory / "verify"
            sources = ROOT / "StrandiOS" / "CloudBackup"
            subprocess.run(
                [
                    SWIFTC,
                    "-module-cache-path", str(directory / "modules"),
                    str(sources / "PulseCloudUpload.swift"),
                    str(sources / "PulseCloudAPI.swift"),
                    str(sources / "PulseCloudBackupPolicy.swift"),
                    str(ROOT / "Strand/Data/CloudBackupCore/CloudBackupEncryption.swift"),
                    str(ROOT / "Strand/Data/CloudBackupCore/CloudBackupProtection.swift"),
                    str(main),
                    "-o", str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable), str(directory)], check=True)
