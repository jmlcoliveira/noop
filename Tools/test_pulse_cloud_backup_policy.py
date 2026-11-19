import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc")

HARNESS = r"""
import Foundation

typealias Policy = PulseCloudBackupPolicy

precondition(Policy.reconcileDeletion(requestedGeneration: 4, installationID: "phone",
                                      serverGeneration: 4, activeDeviceID: "phone") == .awaitingReceipt)
precondition(Policy.reconcileDeletion(requestedGeneration: 4, installationID: "phone",
                                      serverGeneration: 5, activeDeviceID: "phone") == .completed)
precondition(Policy.reconcileDeletion(requestedGeneration: 4, installationID: "phone",
                                      serverGeneration: 5, activeDeviceID: "other") == .superseded)
precondition(Policy.reconcileDeletion(requestedGeneration: 4, installationID: "phone",
                                      serverGeneration: 6, activeDeviceID: "phone") == .superseded)
precondition(Policy.reconcileDeletion(requestedGeneration: 4, installationID: nil,
                                      serverGeneration: 5, activeDeviceID: nil) == .superseded)

precondition(Policy.shouldDiscardStagedUpload(httpStatus: 422, code: "checksum_mismatch"))
precondition(Policy.shouldDiscardStagedUpload(httpStatus: 422, code: "invalid_part_size"))
precondition(Policy.shouldDiscardStagedUpload(httpStatus: 409, code: "backup_id_used"))
precondition(Policy.shouldDiscardStagedUpload(httpStatus: 409, code: "part_already_uploaded"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: 409, code: "device_conflict"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: 409, code: "parts_incomplete"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: 409, code: "upload_invalidated"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: 401, code: "unauthorized"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: 503, code: "temporarily_unavailable"))
precondition(!Policy.shouldDiscardStagedUpload(httpStatus: nil, code: nil))

// A restored preferences domain can own a local UUID even when the user was signed out.
precondition(Policy.requiresReplacementInstallation(savedInstallationID: "phone", keychainDeviceID: nil))
precondition(Policy.requiresReplacementInstallation(savedInstallationID: "phone", keychainDeviceID: "other"))
precondition(!Policy.requiresReplacementInstallation(savedInstallationID: "phone", keychainDeviceID: "phone"))
precondition(!Policy.requiresReplacementInstallation(savedInstallationID: nil, keychainDeviceID: nil))

struct Backup: Identifiable { let id: Int }
let previous = (1...7).reversed().map { Backup(id: $0) }
precondition(Policy.history(afterSaving: Backup(id: 8), previous: previous).map(\.id) == [8, 7, 6, 5, 4, 3, 2])
precondition(Policy.history(afterSaving: Backup(id: 7), previous: previous).map(\.id) == [7, 6, 5, 4, 3, 2, 1])

precondition(Policy.shouldProbeAccount(deletionStarted: true, rejectedSignInCode: "INVALID_LOGIN_CREDENTIALS"))
precondition(Policy.shouldProbeAccount(deletionStarted: true, rejectedSignInCode: "EMAIL_NOT_FOUND"))
precondition(!Policy.shouldProbeAccount(deletionStarted: false, rejectedSignInCode: "INVALID_LOGIN_CREDENTIALS"))
precondition(!Policy.shouldProbeAccount(deletionStarted: true, rejectedSignInCode: "TOO_MANY_ATTEMPTS_TRY_LATER"))
precondition(Policy.accountUnavailableAfterDeletion(refreshFailureCode: "USER_NOT_FOUND"))
precondition(Policy.accountUnavailableAfterDeletion(refreshFailureCode: "USER_DISABLED"))
precondition(!Policy.accountUnavailableAfterDeletion(refreshFailureCode: "INVALID_REFRESH_TOKEN"))
precondition(!Policy.accountUnavailableAfterDeletion(refreshFailureCode: nil))
"""


@unittest.skipUnless(SWIFTC, "Requires Swift to exercise the iPhone backup policies")
class CloudBackupPolicyTests(unittest.TestCase):
    def test_account_and_upload_recovery(self):
        with tempfile.TemporaryDirectory(prefix="pulse-cloud-policy-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(HARNESS, encoding="utf-8")
            executable = directory / "verify"
            subprocess.run(
                [
                    SWIFTC,
                    "-module-cache-path", str(directory / "modules"),
                    str(ROOT / "StrandiOS/CloudBackup/PulseCloudBackupPolicy.swift"),
                    str(main),
                    "-o", str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable)], check=True)
