import Foundation

/// Decisions shared by the coordinator and its offline tests.
enum PulseCloudBackupPolicy {
    enum DeletionReconciliation: Equatable {
        case awaitingReceipt
        case completed
        case superseded
    }

    static func reconcileDeletion(
        requestedGeneration: Int, installationID: String?, serverGeneration: Int, activeDeviceID: String?
    ) -> DeletionReconciliation {
        guard let installationID, activeDeviceID == installationID else { return .superseded }
        if serverGeneration == requestedGeneration { return .awaitingReceipt }
        let (nextGeneration, overflow) = requestedGeneration.addingReportingOverflow(1)
        if !overflow, serverGeneration == nextGeneration { return .completed }
        return .superseded
    }

    static func shouldDiscardStagedUpload(httpStatus: Int?, code: String?) -> Bool {
        switch (httpStatus, code) {
        case (422, "checksum_mismatch"), (422, "invalid_part_size"),
             (409, "backup_id_used"), (409, "part_already_uploaded"): true
        default: false
        }
    }

    static func requiresReplacementInstallation(savedInstallationID: String?, keychainDeviceID: String?) -> Bool {
        guard let savedInstallationID else { return false }
        return savedInstallationID != keychainDeviceID
    }

    static func history<Backup: Identifiable>(afterSaving backup: Backup, previous: [Backup]) -> [Backup] {
        // Match the Worker's retention when reflecting a completed transfer before the next refresh.
        Array(([backup] + previous.filter { $0.id != backup.id }).prefix(7))
    }

    static func shouldProbeAccount(deletionStarted: Bool, rejectedSignInCode: String?) -> Bool {
        guard deletionStarted else { return false }
        switch rejectedSignInCode {
        case "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD", "EMAIL_NOT_FOUND", "USER_NOT_FOUND", "USER_DISABLED":
            return true
        default:
            return false
        }
    }

    static func accountUnavailableAfterDeletion(refreshFailureCode: String?) -> Bool {
        refreshFailureCode == "USER_NOT_FOUND" || refreshFailureCode == "USER_DISABLED"
    }

    static func sameEmail(_ left: String, _ right: String) -> Bool {
        !left.isEmpty && left.lowercased() == right.lowercased()
    }

    static func sameAccount(expectedID: String, expectedEmail: String, id: String, email: String) -> Bool {
        !expectedID.isEmpty && id == expectedID && sameEmail(expectedEmail, email)
    }
}
