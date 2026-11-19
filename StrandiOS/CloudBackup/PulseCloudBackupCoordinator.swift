import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class PulseCloudBackupCoordinator: ObservableObject {
    static let shared = PulseCloudBackupCoordinator()
    static var localWorkInProgress: () -> Bool = { false }

    enum Activity: Equatable {
        case account
        case checking
        case preparing
        case uploading(Int?)
        case downloading
        case deleting

        var title: LocalizedStringKey {
            switch self {
            case .account: "Updating account…"
            case .checking: "Checking backups…"
            case .preparing: "Preparing encrypted backup…"
            case .uploading(nil): "Waiting to upload…"
            case .uploading: "Uploading encrypted backup…"
            case .downloading: "Downloading and verifying backup…"
            case .deleting: "Deleting cloud data…"
            }
        }
    }

    private struct Preferences: Codable {
        var accountID: String?
        var verifiedEmail: Bool?
        var generation: Int?
        var automatic = false
        var wifiOnly = true
        var lastSuccess: Date?
        var fingerprint: String?
        var nextAttempt: Date?
        var failures = 0
        var pending: PulseCloudPendingUpload?
        var abandonedUpload: AbandonedMultipart?
        var deletingBackupsFromGeneration: Int?
        var deletionStarted = false
    }

    private struct AbandonedMultipart: Codable, Equatable {
        let id: String
        let accountID: String
        let generation: Int
    }

    private static let preferencesKey = "pulse.cloud.preferences.v1"
    private static let installationIDKey = "pulse.cloud.installation.v1"
    private static let daily: TimeInterval = 24 * 60 * 60

    @Published private(set) var email: String?
    @Published private(set) var emailVerified = false
    @Published private(set) var signInMethods: Set<PulseCloudSignInMethod> = []
    @Published private var googleLink: PulseGoogleLink?
    @Published private(set) var state: PulseCloudState?
    @Published private(set) var activity: Activity?
    @Published private(set) var errorMessage: String?
    @Published private(set) var message: String?
    @Published private var preferences = Preferences()
    @Published private(set) var hasPendingRestore = false
    @Published private(set) var restoreOutcome: CloudBackupSnapshot.RestoreOutcome?
    @Published private(set) var hasRecoveryCode = false

    var configured: Bool { PulseCloudAuth.apiKey != nil }
    var automatic: Bool { preferences.automatic }
    var wifiOnly: Bool { preferences.wifiOnly }
    var lastSuccess: Date? { preferences.lastSuccess }
    var pendingRetry: Date? { preferences.failures > 0 ? preferences.nextAttempt : nil }
    var deletionStarted: Bool { preferences.deletionStarted }
    var googleLinkEmail: String? { googleLink?.email }
    var backupsDeletionPending: Bool { preferences.deletingBackupsFromGeneration != nil }
    var canCancelUpload: Bool {
        if case .uploading = activity { return true }
        return false
    }
    var activeHere: Bool {
        guard let generation = preferences.generation else { return false }
        guard let state else { return true }
        return state.activeDeviceId == installationID && state.generation == generation
    }

    private let defaults = UserDefaults.standard
    private let auth = PulseCloudAuth()
    private let googleSignIn = PulseGoogleSignIn()
    private let api = PulseCloudAPI()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var wifiAvailable: Bool?
    private var account: PulseCloudAccount?
    private var cachedCredential: PulseCloudCredential?
    private var installationID: String?
    private var sessionLoaded = false
    private var partProgress: [Int: Double] = [:]
    private var failedUploadID: String?

    private init() {
        installationID = defaults.string(forKey: Self.installationIDKey)
        if let bytes = defaults.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: bytes) {
            preferences = saved
        }
        hasPendingRestore = CloudBackupSnapshot.hasPendingRestore
        PulseCloudPendingUpload.cleanOrphans(keeping: preferences.pending?.id)
    }

    func appBecameActive() {
        guard configured else { return }
        loadSession()
        refreshRestoreStatus()
        guard shouldRunAutomatically else { return }
        if wifiOnly { monitorWiFi() }
        Task { await runAutomaticBackupIfDue() }
    }

    func refreshRestoreStatus() {
        hasPendingRestore = CloudBackupSnapshot.hasPendingRestore
        restoreOutcome = CloudBackupSnapshot.lastRestoreOutcome
    }

    func updateBackgroundSchedule() {
        loadSession()
        guard shouldRunAutomatically else {
            PulseCloudBackupScheduler.cancel()
            return
        }
        // Allow the OS-owned upload to finish before asking for another processing wake.
        let fallback = preferences.pending == nil ? Date() : Date().addingTimeInterval(60 * 60)
        PulseCloudBackupScheduler.schedule(after: max(preferences.nextAttempt ?? fallback, fallback))
    }

    func runAutomaticBackupIfDue() async {
        loadSession()
        guard shouldRunAutomatically, activity == nil,
              preferences.nextAttempt.map({ $0 <= Date() }) ?? true else {
            updateBackgroundSchedule()
            return
        }
        await withActivity(.checking, reportRetry: true) { try await self.performBackup(force: false) }
        updateBackgroundSchedule()
    }

    func screenOpened() async {
        loadSession()
        if account != nil && wifiOnly { monitorWiFi() }
        if account != nil && !deletionStarted { await refresh() }
        refreshRestoreStatus()
        if activity == nil, let pending = preferences.pending,
           await PulseCloudTransfers.shared.contains(id: pending.id),
           activity == nil, preferences.pending?.id == pending.id {
            activity = .uploading(nil)
        }
    }

    func signIn(email: String, password: String, create: Bool) async {
        await withActivity(.account) {
            let credential = try await self.auth.authenticate(email: email, password: password, create: create)
            try await self.adoptSignIn(credential)
            if create && !self.deletionStarted {
                try await self.auth.sendVerification(idToken: credential.idToken)
                self.message = String(localized: "Verification email sent.")
            }
        }
    }

    func continueWithGoogle() async {
        await withActivity(.account) {
            self.googleLink = nil
            switch try await self.googleAuthentication() {
            case .signedIn(let credential):
                try await self.adoptSignIn(credential)
            case .confirmPassword(let link):
                self.googleLink = link
            }
        }
    }

    func completeGoogleLink(password: String) async {
        await withActivity(.account) {
            guard let link = self.googleLink else { return }
            let existing = try await self.auth.authenticate(email: link.email, password: password, create: false)
            let linked: PulseCloudCredential
            do {
                linked = try await self.auth.linkGoogle(link, to: existing)
            } catch {
                self.googleLink = nil
                throw error
            }
            self.googleLink = nil
            try await self.adoptSignIn(linked)
        }
    }

    func cancelGoogleLink() {
        guard activity == nil else { return }
        googleLink = nil
        errorMessage = nil
    }

    func addPassword(_ password: String) async -> Bool {
        await withActivity(.account) {
            guard let account = self.account, !self.deletionStarted,
                  self.signInMethods == [.google] else { throw LocalActionError.signInRequired }
            let fresh = try await self.reauthenticateWithGoogle(account)
            let current = try await self.auth.resolveAccountMethods(fresh)
            guard current.account.signInMethods?.contains(.password) == false else {
                try self.use(current, installationID: self.ensureInstallationID())
                throw LocalActionError.passwordAlreadySet
            }
            let linked = try await self.auth.addPassword(password, to: current)
            try self.use(linked, installationID: self.ensureInstallationID())
            self.message = String(localized: "Password sign-in added to your Pulse account.")
        }
    }

    func sendVerification() async {
        await withActivity(.account) {
            let credential = try await self.credential()
            try await self.auth.sendVerification(idToken: credential.idToken)
            self.message = String(localized: "Verification email sent.")
        }
    }

    func resetPassword(email: String) async {
        await withActivity(.account) {
            try await self.auth.sendPasswordReset(email: email)
            self.message = String(localized: "If that email has a Pulse account, a password reset link has been sent.")
        }
    }

    func refresh() async {
        await withActivity(.checking) {
            let credential = try await self.credential(force: !self.emailVerified)
            if let resolved = try? await self.auth.resolveAccountMethods(credential), let installationID = self.installationID {
                try self.use(resolved, installationID: installationID)
            }
            guard credential.emailVerified else { return }
            try await self.loadRemoteState(token: credential.idToken)
        }
    }

    func setWifiOnly(_ value: Bool) {
        guard activity == nil else { return }
        preferences.wifiOnly = value
        persist()
        if value { monitorWiFi() }
        updateBackgroundSchedule()
    }

    func setAutomatic(_ value: Bool) {
        guard activity == nil, activeHere, !hasPendingRestore else { return }
        guard !value || (hasRecoveryCode && !backupsDeletionPending) else { return }
        preferences.automatic = value
        if value { preferences.nextAttempt = nil }
        persist()
        updateBackgroundSchedule()
        if value { Task { await runAutomaticBackupIfDue() } }
    }

    func storedRecoveryCode() throws -> String? {
        guard let account else { return nil }
        return try CloudBackupKeychain.load(accountID: account.id)?.code
    }

    func enableBackup(
        using recoveryKey: CloudBackupRecoveryKey, reviewed: PulseCloudState
    ) async -> Bool {
        await withActivity(.checking) {
            guard !self.hasPendingRestore, !self.deletionStarted else { return }
            let credential = try await self.credential()
            let current = try await self.api.state(token: credential.idToken)
            self.accept(current)
            guard current.generation == reviewed.generation,
                  current.activeDeviceId == reviewed.activeDeviceId,
                  current.backups.first?.id == reviewed.backups.first?.id else {
                throw LocalActionError.backupsChanged
            }
            let device = try self.deviceIdentity()
            // Save the code before claiming so a Keychain failure cannot move the active device.
            try CloudBackupKeychain.save(recoveryKey, accountID: credential.account.id)
            self.hasRecoveryCode = true
            let claimed = try await self.api.claim(device: device, generation: current.generation, token: credential.idToken)
            self.preferences.generation = claimed.generation
            self.preferences.automatic = true
            self.preferences.nextAttempt = nil
            self.preferences.failures = 0
            self.preferences.fingerprint = nil
            self.persist()
            self.accept(claimed)
            self.updateBackgroundSchedule()
        }
    }

    func backupNow() async {
        await withActivity(.checking, reportRetry: true) { try await self.performBackup(force: true) }
        updateBackgroundSchedule()
    }

    func cancelUpload() async {
        guard case .uploading = activity else { return }
        activity = .checking
        await stopPendingUpload()
        preferences.nextAttempt = Date().addingTimeInterval(Self.daily)
        persist()
        activity = nil
        message = String(localized: "Upload stopped on this iPhone. Refresh to check which backups were saved.")
        updateBackgroundSchedule()
    }

    func restore(
        _ backup: PulseCloudBackup, using recoveryKey: CloudBackupRecoveryKey
    ) async -> Bool {
        await withActivity(.downloading) {
            guard !self.hasPendingRestore, let state = self.state, !self.deletionStarted else { return }
            try self.requireTransferNetwork()
            let credential = try await self.credential()
            let directory = try CloudBackupFiles.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try await self.api.download(backup, into: directory, maxBytes: state.maxBackupBytes,
                                                   token: credential.idToken, wifiOnly: self.wifiOnly)
            let stage = Task.detached(priority: .utility) {
                try CloudBackupSnapshot.stageRestore(from: file, sha256: backup.sha256, using: recoveryKey)
            }
            try await withTaskCancellationHandler(operation: { try await stage.value }, onCancel: {
                stage.cancel()
            })
            self.refreshRestoreStatus()
            // An older backup might have used an earlier recovery code. Preserve the active key.
            if !self.activeHere || !self.hasRecoveryCode {
                try CloudBackupKeychain.save(recoveryKey, accountID: credential.account.id)
                self.hasRecoveryCode = true
            }
            self.preferences.nextAttempt = Date().addingTimeInterval(Self.daily)
            self.persist()
            self.updateBackgroundSchedule()
        }
    }

    func deleteBackups() async {
        await withActivity(.deleting, stopsUpload: true) {
            guard !self.hasPendingRestore, !self.deletionStarted else { return }
            guard let generation = self.preferences.generation else { throw PulseCloudAPIError.deviceConflict }
            self.preferences.automatic = false
            self.preferences.deletingBackupsFromGeneration = generation
            self.persist()
            self.updateBackgroundSchedule()
            await self.stopPendingUpload()
            let credential = try await self.credential()
            let newGeneration = try await self.api.deleteBackups(
                device: self.deviceIdentity(), generation: generation, token: credential.idToken)
            self.completeBackupDeletion(generation: newGeneration)
            if let current = self.state {
                self.state = PulseCloudState(activeDeviceId: current.activeDeviceId, generation: newGeneration,
                                             backups: [], maxBackupBytes: current.maxBackupBytes)
            }
        }
    }

    func deleteAccount(using method: PulseCloudSignInMethod, password: String = "") async -> Bool {
        let deleted = await withActivity(.deleting, stopsUpload: true) {
            guard let account = self.account, !self.hasPendingRestore else { return }
            guard let fresh = try await self.reauthenticateForDeletion(account, method: method, password: password) else {
                try self.clearSession()
                self.message = String(localized: "Cloud backups were deleted. Your local data is still on this iPhone.")
                return
            }
            try self.auth.requireSameAccount(fresh, as: account)
            self.preferences.automatic = false
            self.persist()
            self.updateBackgroundSchedule()
            await self.stopPendingUpload()
            if !self.deletionStarted {
                // Delete encrypted data before deleting the only credential that can authorize it.
                try await self.api.deleteAccount(token: fresh.idToken)
                self.preferences.deletionStarted = true
                self.persist()
                self.state = nil
            }
            try await self.auth.deleteAccount(idToken: fresh.idToken)
            try self.clearSession()
            self.message = String(localized: "Pulse account deleted. Your local data is still on this iPhone.")
        }
        if !deleted, activity == nil, let pending = preferences.pending,
           await PulseCloudTransfers.shared.contains(id: pending.id),
           activity == nil, preferences.pending?.id == pending.id {
            activity = .uploading(nil)
        }
        return deleted
    }

    func signOut() async {
        await withActivity(.account, stopsUpload: true) {
            self.preferences.automatic = false
            self.persist()
            self.updateBackgroundSchedule()
            await self.stopPendingUpload()
            try self.clearSession(preservePendingDeletion: self.deletionStarted)
            self.message = String(localized: "Signed out. Your local data is still on this iPhone.")
        }
    }

    func uploadProgress(_ upload: PulseCloudUploadTask, fraction: Double) {
        guard let pending = preferences.pending, pending.id == upload.backupID,
              failedUploadID != upload.backupID, fraction.isFinite,
              activity == nil || canCancelUpload else { return }
        let clipped = min(1, max(0, fraction))
        let overall: Double
        if case .part(let number) = upload.kind, let parts = pending.parts {
            partProgress[number] = clipped
            let uploaded = parts.reduce(0.0) { total, part in
                let fraction = pending.receivedParts?.contains(part.number) == true ? 1 : partProgress[part.number] ?? 0
                return total + Double(part.size) * fraction
            }
            overall = min(0.99, uploaded / Double(pending.size))
        } else {
            overall = clipped
        }
        let progress = Activity.uploading(Int(overall * 20) * 5)
        if progress != activity { activity = progress }
    }

    func uploadCompleted(
        _ upload: PulseCloudUploadTask, result: Result<PulseCloudUploadReceipt, any Error>
    ) -> (() async -> Void)? {
        guard var pending = preferences.pending, pending.id == upload.backupID,
              pending.generation == preferences.generation else { return nil }
        switch result {
        case .success(.backup(let backup)) where pending.matches(backup):
            if canCancelUpload { activity = nil }
            finishUpload(backup, pending: pending)
            updateBackgroundSchedule()
        case .success(.part):
            guard case .part(let number) = upload.kind, pending.parts?.contains(where: { $0.number == number }) == true
            else { return nil }
            guard pending.receivedParts?.insert(number).inserted == true else { return nil }
            preferences.pending = pending
            persist()
            partProgress.removeValue(forKey: number)
            if pending.allPartsReceived, failedUploadID != pending.id {
                return { await self.completeMultipartAfterParts(id: pending.id) }
            }
        case .success(.backup):
            return uploadFailed(PulseCloudAPIError.invalidResponse, pending: pending)
        case .failure(let error):
            return uploadFailed(error, pending: pending)
        }
        return nil
    }

    private func uploadFailed(_ error: any Error, pending: PulseCloudPendingUpload) -> (() async -> Void)? {
        let cloudError = error as? PulseCloudAPIError
        let discard = cloudError?.shouldDiscardUpload == true
        if failedUploadID == pending.id, !discard && cloudError?.needsDeviceReview != true { return nil }
        failedUploadID = pending.id
        if discard {
            rememberAbandonedMultipart(pending)
            preferences.pending = nil
        }
        recordFailure(error, retry: true)
        updateBackgroundSchedule()
        if !pending.isMultipart {
            if discard { pending.discard() }
            if canCancelUpload { activity = nil }
            return nil
        }
        return {
            await PulseCloudTransfers.shared.cancel(id: pending.id)
            if discard { pending.discard() }
            if self.failedUploadID == pending.id, self.canCancelUpload { self.activity = nil }
        }
    }

    private var shouldRunAutomatically: Bool {
        configured && account != nil && preferences.automatic && preferences.generation != nil
            && !hasPendingRestore && !deletionStarted && !backupsDeletionPending
            && defaults.string(forKey: "noop.acceptedTermsVersion") == Terms.currentVersion
    }

    @discardableResult
    private func withActivity(
        _ operation: Activity, reportRetry: Bool = false, stopsUpload: Bool = false,
        run: () async throws -> Void
    ) async -> Bool {
        guard activity == nil || (stopsUpload && canCancelUpload) else { return false }
        activity = operation
        errorMessage = nil
        message = nil
        defer { if !canCancelUpload { activity = nil } }
        do {
            try await run()
            return true
        } catch is CancellationError {
            return false
        } catch {
            recordFailure(error, retry: reportRetry)
            return false
        }
    }

    private func performBackup(force: Bool) async throws {
        guard defaults.string(forKey: "noop.acceptedTermsVersion") == Terms.currentVersion else { return }
        guard activeHere, !hasPendingRestore, !deletionStarted else { throw PulseCloudAPIError.deviceConflict }
        guard !backupsDeletionPending else { return }
        guard let generation = preferences.generation else { throw PulseCloudAPIError.deviceConflict }
        if let pending = preferences.pending, await PulseCloudTransfers.shared.contains(id: pending.id),
           preferences.pending?.id == pending.id {
            activity = .uploading(nil)
            return
        }
        if deferAutomaticBackupIfNeeded(force: force, needsExternalPower: preferences.pending == nil) { return }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw LocalActionError.thermalLimit }
        try requireTransferNetwork()
        let initialCredential = try await credential()
        let current = try await api.state(token: initialCredential.idToken)
        accept(current)
        let device = try deviceIdentity()
        guard current.activeDeviceId == device.id, current.generation == generation else {
            throw PulseCloudAPIError.deviceConflict
        }
        try await abortAbandonedMultipart(device: device, credential: initialCredential)
        if let pending = preferences.pending {
            if let backup = current.backups.first(where: pending.matches) {
                finishUpload(backup, pending: pending)
                if !force { return }
            } else if (!force || pending.isMultipart), pending.generation == generation, pending.retainedFilesExist {
                try await enqueue(pending, device: device)
                return
            } else {
                await stopPendingUpload()
                try await abortAbandonedMultipart(device: device, credential: initialCredential)
            }
        }
        if deferAutomaticBackupIfNeeded(force: force, needsExternalPower: true) { return }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw LocalActionError.thermalLimit }
        guard let key = try CloudBackupKeychain.load(accountID: initialCredential.account.id) else {
            throw PulseCloudAPIError.recoveryKeyMissing
        }
        activity = .preparing
        let priorFingerprint = preferences.fingerprint
        let maxBytes = current.maxBackupBytes
        let preparation = Task.detached(priority: .utility) { () throws -> PulseCloudPendingUpload? in
            let directory = try CloudBackupFiles.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            guard let prepared = try CloudBackupSnapshot.prepareIfChanged(
                in: directory, using: key, previousFingerprint: force ? nil : priorFingerprint
            ) else { return nil }
            guard prepared.byteCount > 0, prepared.byteCount <= maxBytes else { throw PulseCloudAPIError.tooLarge }
            var pending = PulseCloudPendingUpload(
                id: UUID().uuidString.lowercased(), generation: generation,
                size: prepared.byteCount, sha256: prepared.sha256, fingerprint: prepared.fingerprint)
            try pending.retain(file: prepared.fileURL)
            return pending
        }
        let pending = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: {
            preparation.cancel()
        })
        if Task.isCancelled {
            pending?.discard()
            throw CancellationError()
        }
        guard let pending else {
            preferences.nextAttempt = Date().addingTimeInterval(Self.daily)
            preferences.failures = 0
            persist()
            return
        }
        preferences.pending = pending
        preferences.nextAttempt = nil
        persist()
        try await enqueue(pending, device: device)
    }

    private func deferAutomaticBackupIfNeeded(force: Bool, needsExternalPower: Bool) -> Bool {
        guard !force else { return false }
        let process = ProcessInfo.processInfo
        guard process.isLowPowerModeEnabled || process.thermalState == .serious
                || process.thermalState == .critical || Self.localWorkInProgress()
                || (needsExternalPower && !isOnExternalPower) else {
            return false
        }
        preferences.nextAttempt = Date().addingTimeInterval(60 * 60)
        persist()
        return true
    }

    private var isOnExternalPower: Bool {
        let phone = UIDevice.current
        if !phone.isBatteryMonitoringEnabled { phone.isBatteryMonitoringEnabled = true }
        return phone.batteryState == .charging || phone.batteryState == .full
    }

    private func enqueue(_ pending: PulseCloudPendingUpload, device: PulseCloudDevice) async throws {
        let uploadCredential = try await credential(force: true)
        try Task.checkCancellation()
        failedUploadID = nil
        partProgress.removeAll()
        if let parts = pending.parts {
            let status: PulseCloudMultipartStatus
            do {
                status = try await api.startMultipart(pending, device: device, token: uploadCredential.idToken)
            } catch let error as PulseCloudAPIError where error.shouldDiscardUpload {
                rememberAbandonedMultipart(pending)
                preferences.pending = nil
                persist()
                pending.discard()
                throw error
            }
            try Task.checkCancellation()
            if let completed = status.backup {
                guard pending.matches(completed) else { throw PulseCloudAPIError.invalidResponse }
                finishUpload(completed, pending: pending)
                return
            }
            var current = pending
            try current.accept(status)
            preferences.pending = current
            preferences.nextAttempt = nil
            persist()
            if current.allPartsReceived {
                enqueueMultipartCompletion(current, device: device, token: uploadCredential.idToken)
            } else {
                activity = .uploading(nil)
                for part in parts where current.receivedParts?.contains(part.number) == false {
                    let request = api.partRequest(part, upload: current, device: device, token: uploadCredential.idToken)
                    PulseCloudTransfers.shared.enqueue(request, file: current.file(for: part.number),
                        upload: PulseCloudUploadTask(backupID: current.id, kind: .part(part.number)), wifiOnly: wifiOnly)
                }
            }
        } else {
            let request = api.uploadRequest(id: pending.id, size: pending.size, sha256: pending.sha256,
                                        device: device, generation: pending.generation, token: uploadCredential.idToken)
            activity = .uploading(nil)
            PulseCloudTransfers.shared.enqueue(request, file: pending.fileURL,
                upload: PulseCloudUploadTask(backupID: pending.id, kind: .direct), wifiOnly: wifiOnly)
        }
    }

    private func enqueueMultipartCompletion(_ pending: PulseCloudPendingUpload, device: PulseCloudDevice, token: String) {
        let request = api.completeMultipartRequest(pending, device: device, token: token)
        activity = .uploading(100)
        PulseCloudTransfers.shared.enqueue(request, file: pending.completionFile,
            upload: PulseCloudUploadTask(backupID: pending.id, kind: .complete), wifiOnly: wifiOnly)
    }

    private func completionReady(id: String) -> Bool {
        preferences.pending?.id == id && preferences.pending?.allPartsReceived == true && failedUploadID != id
            && (activity == nil || canCancelUpload) && activeHere && !hasPendingRestore
            && !deletionStarted && !backupsDeletionPending
            && defaults.string(forKey: "noop.acceptedTermsVersion") == Terms.currentVersion
    }

    private func completeMultipartAfterParts(id: String) async {
        guard completionReady(id: id), let pending = preferences.pending else { return }
        activity = .uploading(100)
        do {
            let credential = try await credential()
            guard completionReady(id: id) else { return }
            enqueueMultipartCompletion(pending, device: try deviceIdentity(), token: credential.idToken)
        } catch {
            guard completionReady(id: id) else { return }
            await uploadFailed(error, pending: pending)?()
        }
    }

    private func finishUpload(_ backup: PulseCloudBackup, pending: PulseCloudPendingUpload) {
        preferences.pending = nil
        preferences.lastSuccess = backup.createdAt
        preferences.fingerprint = pending.fingerprint
        preferences.failures = 0
        preferences.nextAttempt = Date().addingTimeInterval(Self.daily)
        persist()
        partProgress.removeAll()
        failedUploadID = nil
        pending.discard()
        errorMessage = nil
        if let state {
            // The service owns retention. Refresh the list on the next visit to the screen.
            self.state = PulseCloudState(activeDeviceId: state.activeDeviceId, generation: state.generation,
                backups: PulseCloudBackupPolicy.history(afterSaving: backup, previous: state.backups),
                maxBackupBytes: state.maxBackupBytes)
        }
    }

    private func stopPendingUpload() async {
        guard let pending = preferences.pending else { return }
        rememberAbandonedMultipart(pending)
        preferences.pending = nil
        persist()
        partProgress.removeAll()
        failedUploadID = nil
        await PulseCloudTransfers.shared.cancel(id: pending.id)
        pending.discard()
        if pending.isMultipart, let current = try? await credential(), let device = try? deviceIdentity() {
            try? await abortAbandonedMultipart(device: device, credential: current)
        }
    }

    private func rememberAbandonedMultipart(_ pending: PulseCloudPendingUpload) {
        guard pending.isMultipart, let accountID = preferences.accountID else { return }
        preferences.abandonedUpload = AbandonedMultipart(id: pending.id, accountID: accountID,
                                                         generation: pending.generation)
    }

    private func abortAbandonedMultipart(device: PulseCloudDevice, credential: PulseCloudCredential) async throws {
        guard let abandoned = preferences.abandonedUpload, abandoned.accountID == credential.account.id else { return }
        if abandoned.generation == preferences.generation {
            try await api.abortMultipart(id: abandoned.id, generation: abandoned.generation,
                                        device: device, token: credential.idToken)
        }
        guard preferences.abandonedUpload == abandoned else { return }
        preferences.abandonedUpload = nil
        persist()
    }

    private func loadSession() {
        guard !sessionLoaded, let installationID, configured else { return }
        do {
            let loaded = try PulseCloudSecureStore.load(PulseCloudAccount.self, name: installationID)
            // A restored preferences domain alone is insufficient to resume a backup session.
            if loaded?.id == preferences.accountID {
                account = loaded
                email = loaded?.email
                if let loaded {
                    emailVerified = preferences.verifiedEmail == true
                    signInMethods = loaded.signInMethods ?? []
                    hasRecoveryCode = (try? CloudBackupKeychain.load(accountID: loaded.id)) != nil
                }
            }
            sessionLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func credential(force: Bool = false) async throws -> PulseCloudCredential {
        loadSession()
        guard let account, let installationID else { throw LocalActionError.signInRequired }
        if !force, let cachedCredential, cachedCredential.expiresAt.timeIntervalSinceNow > 5 * 60 {
            return cachedCredential
        }
        let credential = try await auth.refresh(account)
        try use(credential, installationID: installationID)
        return credential
    }

    private func googleAuthentication(existingOnly: Bool = false) async throws -> PulseGoogleResult {
        let authorization = try await auth.googleAuthorization()
        let requestURI = try await googleSignIn.authorize(authorization)
        return try await auth.authenticateGoogle(requestURI: requestURI, sessionID: authorization.sessionID,
                                                 existingOnly: existingOnly)
    }

    private func reauthenticateWithGoogle(_ account: PulseCloudAccount) async throws -> PulseCloudCredential {
        guard case .signedIn(let fresh) = try await googleAuthentication(existingOnly: true) else {
            throw PulseCloudAuthError.differentAccount
        }
        try auth.requireSameAccount(fresh, as: account)
        return fresh
    }

    private func adoptSignIn(_ credential: PulseCloudCredential) async throws {
        let deviceWasRestored = try needsNewInstallationID()
        if deviceWasRestored { installationID = nil }
        if deviceWasRestored || preferences.accountID != credential.account.id {
            let oldPending = preferences.pending
            let pendingDeletion = preferences.accountID == credential.account.id && deletionStarted
            let abandoned = preferences.abandonedUpload.flatMap { $0.accountID == credential.account.id ? $0 : nil }
            preferences = Preferences(accountID: credential.account.id, abandonedUpload: abandoned,
                                      deletionStarted: pendingDeletion)
            persist()
            if let oldPending {
                await PulseCloudTransfers.shared.cancel(id: oldPending.id)
                oldPending.discard()
            }
            state = nil
        }
        try use(credential, installationID: ensureInstallationID())
        guard !deletionStarted, credential.emailVerified else { return }
        try await loadRemoteState(token: credential.idToken)
        if let resolved = try? await auth.resolveAccountMethods(credential) {
            try use(resolved, installationID: ensureInstallationID())
        }
        appBecameActive()
    }

    private func reauthenticateForDeletion(
        _ account: PulseCloudAccount, method: PulseCloudSignInMethod, password: String
    ) async throws -> PulseCloudCredential? {
        if method == .google {
            // Firebase may have completed the prior deletion after Pulse lost the response.
            if deletionStarted, try await confirmDeletedAccount(account) { return nil }
            return try await reauthenticateWithGoogle(account)
        }
        do {
            return try await auth.authenticate(email: account.email, password: password, create: false)
        } catch let signInError as PulseCloudAuthError where PulseCloudBackupPolicy.shouldProbeAccount(
            deletionStarted: deletionStarted, rejectedSignInCode: signInError.firebaseCode
        ) {
            // Firebase can commit deletion before its response reaches Pulse. A rejected password
            // alone is ambiguous, so confirm account status using the existing refresh credential.
            if try await confirmDeletedAccount(account) { return nil }
            throw signInError
        }
    }

    private func confirmDeletedAccount(_ account: PulseCloudAccount) async throws -> Bool {
        do {
            let refreshed = try await auth.refresh(account)
            if let installationID { try use(refreshed, installationID: installationID) }
            return false
        } catch let error as PulseCloudAuthError where
            PulseCloudBackupPolicy.accountUnavailableAfterDeletion(refreshFailureCode: error.firebaseCode) {
            return true
        }
    }

    private func use(_ incoming: PulseCloudCredential, installationID: String) throws {
        var credential = incoming
        credential.account.signInMethods = credential.signInMethods
        if account != credential.account {
            try PulseCloudSecureStore.save(credential.account, name: installationID)
        }
        if account?.id != credential.account.id {
            hasRecoveryCode = (try? CloudBackupKeychain.load(accountID: credential.account.id)) != nil
        }
        sessionLoaded = true
        account = credential.account
        cachedCredential = credential
        email = credential.account.email
        emailVerified = credential.emailVerified
        signInMethods = credential.signInMethods
        if preferences.verifiedEmail != emailVerified {
            preferences.verifiedEmail = emailVerified
            persist()
        }
    }

    private func loadRemoteState(token: String) async throws {
        let current = try await api.state(token: token)
        accept(current)
    }

    private func accept(_ current: PulseCloudState) {
        state = current
        if let requested = preferences.deletingBackupsFromGeneration {
            switch PulseCloudBackupPolicy.reconcileDeletion(
                requestedGeneration: requested, installationID: installationID,
                serverGeneration: current.generation, activeDeviceID: current.activeDeviceId
            ) {
            case .completed:
                // The Worker advances this device's generation when it commits the wipe.
                // Adopt the receipt even if the original DELETE response never arrived.
                completeBackupDeletion(generation: current.generation)
            case .superseded:
                preferences.deletingBackupsFromGeneration = nil
                persist()
            case .awaitingReceipt:
                break
            }
        }
        if preferences.generation != nil && !activeHere {
            preferences.automatic = false
            preferences.nextAttempt = nil
            preferences.abandonedUpload = nil
            invalidateStagedUpload()
            persist()
            updateBackgroundSchedule()
        }
    }

    private func completeBackupDeletion(generation: Int) {
        preferences.generation = generation
        preferences.deletingBackupsFromGeneration = nil
        preferences.abandonedUpload = nil
        preferences.fingerprint = nil
        preferences.lastSuccess = nil
        preferences.nextAttempt = nil
        preferences.failures = 0
        persist()
        message = String(localized: "Cloud backups deleted.")
    }

    private func clearSession(preservePendingDeletion: Bool = false) throws {
        let pendingDeletionAccount = preservePendingDeletion ? account?.id : nil
        let abandoned = preferences.abandonedUpload
        if let installationID { try PulseCloudSecureStore.remove(name: installationID) }
        if let account { try? CloudBackupKeychain.remove(accountID: account.id) }
        account = nil
        cachedCredential = nil
        email = nil
        emailVerified = false
        signInMethods = []
        hasRecoveryCode = false
        state = nil
        preferences = Preferences(accountID: pendingDeletionAccount, abandonedUpload: abandoned,
                                  deletionStarted: pendingDeletionAccount != nil)
        persist()
    }

    private func ensureInstallationID() -> String {
        if let installationID { return installationID }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.installationIDKey)
        installationID = id
        return id
    }

    private func deviceIdentity() throws -> PulseCloudDevice {
        let id = ensureInstallationID()
        let entry = "device." + id
        let existing = try PulseCloudSecureStore.load(PulseCloudDevice.self, name: entry)
        if let existing { return existing }
        let randomBytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key = randomBytes.map { String(format: "%02x", $0) }.joined()
        let device = PulseCloudDevice(id: id, key: key)
        try PulseCloudSecureStore.save(device, name: entry)
        return device
    }

    private func needsNewInstallationID() throws -> Bool {
        // iPhone migration can restore UserDefaults without restoring ThisDeviceOnly Keychain items.
        let keychainDevice = try installationID.flatMap {
            try PulseCloudSecureStore.load(PulseCloudDevice.self, name: "device." + $0)
        }
        return PulseCloudBackupPolicy.requiresReplacementInstallation(
            savedInstallationID: installationID, keychainDeviceID: keychainDevice?.id)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
    }

    private func recordFailure(_ error: any Error, retry: Bool) {
        errorMessage = error.localizedDescription
        if (error as? PulseCloudAPIError)?.needsDeviceReview == true {
            preferences.automatic = false
            preferences.generation = nil
            preferences.deletingBackupsFromGeneration = nil
            preferences.abandonedUpload = nil
            invalidateStagedUpload()
            preferences.nextAttempt = nil
            state = nil
        } else if (error as? PulseCloudAuthError)?.sessionExpired == true {
            preferences.automatic = false
            account = nil
            cachedCredential = nil
            email = nil
            emailVerified = false
            signInMethods = []
            hasRecoveryCode = false
            state = nil
            if let installationID { try? PulseCloudSecureStore.remove(name: installationID) }
        } else if let cloudError = error as? PulseCloudAPIError, cloudError.shouldPauseAutomatic {
            preferences.automatic = false
            preferences.nextAttempt = nil
            if case .service(410, "account_deleted") = cloudError {
                preferences.abandonedUpload = nil
                invalidateStagedUpload()
            }
        } else if retry {
            let delays: [TimeInterval] = [15 * 60, 60 * 60, 6 * 60 * 60, Self.daily]
            let delay = delays[min(preferences.failures, delays.count - 1)]
            preferences.failures = min(preferences.failures + 1, delays.count)
            preferences.nextAttempt = Date().addingTimeInterval(delay)
        }
        persist()
        if !preferences.automatic { updateBackgroundSchedule() }
    }

    private func invalidateStagedUpload() {
        guard let pending = preferences.pending else { return }
        preferences.pending = nil
        partProgress.removeAll()
        if canCancelUpload { activity = nil }
        Task {
            await PulseCloudTransfers.shared.cancel(id: pending.id)
            pending.discard()
        }
    }

    private func monitorWiFi() {
        guard wifiMonitor.pathUpdateHandler == nil else { return }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.wifiAvailable = available }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "pulse.cloud.wifi"))
    }

    private func requireTransferNetwork() throws {
        guard wifiOnly else { return }
        monitorWiFi()
        if wifiAvailable == false { throw PulseCloudAPIError.wifiUnavailable }
        // If the monitor is still starting, URLSession independently enforces the link policy.
    }

    private enum LocalActionError: LocalizedError {
        case backupsChanged
        case passwordAlreadySet
        case signInRequired
        case thermalLimit

        var errorDescription: String? {
            switch self {
            case .backupsChanged: String(localized: "Your cloud backups changed. Review the updated list before continuing.")
            case .passwordAlreadySet: String(localized: "Your Pulse account already has a password.")
            case .signInRequired: String(localized: "Sign in to your Pulse account to continue.")
            case .thermalLimit: String(localized: "Wait for your iPhone to cool down before backing up.")
            }
        }
    }
}
