import StrandDesign
import SwiftUI
import UIKit

@MainActor
struct PulseCloudBackupView: View {
    @ObservedObject private var cloud = PulseCloudBackupCoordinator.shared
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @State private var sheet: Sheet?
    @State private var confirmDeleteBackups = false
    @State private var confirmDeviceChange = false

    var body: some View {
        ScreenScaffold(title: "Pulse Account & Backup",
                       subtitle: "Keep an encrypted copy of your Pulse history for this iPhone or its replacement.",
                       pulseStyle: true) {
            if cloud.configured {
                if let email = cloud.email {
                    accountCard(email)
                    if !cloud.deletionStarted {
                        if cloud.emailVerified { backupCard } else { verificationCard }
                    }
                    accountActions
                } else {
                    if let linkEmail = cloud.googleLinkEmail {
                        googleLinkCard(linkEmail)
                    } else {
                        signInCard
                    }
                }
            } else {
                card("Cloud backup unavailable", icon: "icloud.slash") {
                    help("This build doesn’t have Pulse Account configured.")
                }
            }
            if let activity = cloud.activity {
                activityCard(activity)
            }
            if let error = cloud.errorMessage {
                status(error, icon: "exclamationmark.circle", color: StrandPalette.statusWarning)
            }
            if let message = cloud.message {
                status(message, icon: "checkmark.circle", color: StrandPalette.accent)
            }
            if let outcome = cloud.restoreOutcome {
                switch outcome {
                case .restored:
                    status(String(localized: "Cloud backup restored."), icon: "checkmark.circle", color: StrandPalette.accent)
                case .failed(let error):
                    status(error, icon: "exclamationmark.circle", color: StrandPalette.statusWarning)
                }
            }
        }
        .task { await cloud.screenOpened() }
        .sheet(item: $sheet) { item in
            switch item {
            case .setup(let state):
                PulseCloudSetupSheet(cloud: cloud, reviewed: state, existingCode: try? cloud.storedRecoveryCode())
            case .restore(let backup):
                PulseCloudRestoreSheet(cloud: cloud, backup: backup)
            case .recoveryCode(let code):
                PulseCloudRecoverySheet(code: code)
            case .deleteAccount:
                PulseCloudDeleteAccountSheet(cloud: cloud)
            case .addPassword:
                PulseCloudAddPasswordSheet(cloud: cloud)
            }
        }
        .alert("Delete every cloud backup?", isPresented: $confirmDeleteBackups) {
            Button("Delete cloud backups", role: .destructive) { Task { await cloud.deleteBackups() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all copies stored with Pulse and turns off automatic backup. Your data stays on this iPhone.")
        }
        .alert("Use this iPhone as the backup device?", isPresented: $confirmDeviceChange) {
            Button("Use this iPhone") {
                if let state = cloud.state { sheet = .setup(state) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pulse will back up the data already on this iPhone. You can also restore an existing backup first. Older cloud backups expire as new ones are saved.")
        }
    }

    private var signInCard: some View {
        card(createAccount ? "Create a Pulse account" : "Sign in", icon: "person.crop.circle") {
            help("A Pulse account is optional. It gives you access to encrypted cloud backup on one active iPhone.")
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .pulseCloudField()
            SecureField("Password", text: $password)
                .textContentType(createAccount ? .newPassword : .password)
                .pulseCloudField()
            NoopButton(createAccount ? "Create account" : "Sign in", fullWidth: true) {
                let address = cleanEmail
                let input = password
                let shouldCreate = createAccount
                password = ""
                Task { await cloud.signIn(email: address, password: input, create: shouldCreate) }
            }
            .disabled(cloud.activity != nil || cleanEmail.isEmpty || password.isEmpty)
            Button {
                createAccount.toggle()
                password = ""
            } label: {
                if createAccount {
                    Text("Already have an account? Sign in")
                } else {
                    Text("Create an account")
                }
            }
            .buttonStyle(NoopButtonStyle(.tertiary))
            .disabled(cloud.activity != nil)
            if !createAccount {
                Button("Send password reset email") { Task { await cloud.resetPassword(email: cleanEmail) } }
                    .buttonStyle(NoopButtonStyle(.tertiary))
                    .disabled(cloud.activity != nil || cleanEmail.isEmpty)
            }
            NoopButton("Continue with Google", kind: .secondary, fullWidth: true) {
                password = ""
                Task { await cloud.continueWithGoogle() }
            }
            .disabled(cloud.activity != nil)
        }
    }

    private func googleLinkCard(_ address: String) -> some View {
        card("Connect Google sign-in", icon: "person.crop.circle") {
            help("Enter your Pulse password for \(address) to connect Google to the same account and backups.")
            SecureField("Pulse password", text: $password)
                .textContentType(.password)
                .pulseCloudField()
            NoopButton("Connect Google", fullWidth: true) {
                let input = password
                password = ""
                Task { await cloud.completeGoogleLink(password: input) }
            }
            .disabled(cloud.activity != nil || password.isEmpty)
            NoopButton("Cancel", kind: .tertiary) {
                password = ""
                cloud.cancelGoogleLink()
            }
            .disabled(cloud.activity != nil)
        }
    }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func accountCard(_ email: String) -> some View {
        card("Pulse Account", icon: "person.crop.circle") {
            Text(email)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .textSelection(.enabled)
            if cloud.deletionStarted {
                help("Cloud data was deleted. Confirm your sign-in to finish deleting your Pulse account.")
            }
        }
    }

    private var verificationCard: some View {
        card("Verify your email", icon: "envelope.badge.shield.half.filled") {
            help("Open the verification link in your inbox, then return here to check your account.")
            NoopButton("Check verification", kind: .secondary) { Task { await cloud.refresh() } }
                .disabled(cloud.activity != nil)
            NoopButton("Resend verification email", kind: .tertiary) { Task { await cloud.sendVerification() } }
                .disabled(cloud.activity != nil)
        }
    }

    private var backupCard: some View {
        VStack(spacing: PulseScreenStyle.sectionSpacing) {
            card("Cloud backup", icon: "lock.icloud") {
                if cloud.hasPendingRestore {
                    Text("Restore ready")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.accent)
                    help("Fully quit and reopen Pulse to finish the restore. Data collected after preparing the restore may be replaced.")
                } else {
                    if let state = cloud.state {
                        if cloud.activeHere {
                            backupControls
                        } else {
                            setupControls(state)
                        }
                        Toggle("Wi-Fi only", isOn: Binding(get: { cloud.wifiOnly }, set: { cloud.setWifiOnly($0) }))
                            .tint(StrandPalette.accent)
                            .disabled(cloud.activity != nil)
                    } else if cloud.activity == nil {
                        NoopButton("Refresh backup status", kind: .secondary) { Task { await cloud.refresh() } }
                    }
                }
            }

            if let state = cloud.state, !state.backups.isEmpty, !cloud.hasPendingRestore {
                card("Restore a backup", icon: "arrow.clockwise.icloud") {
                    help("Restore replaces this iPhone’s Pulse history and included settings after you reopen the app.")
                    ForEach(state.backups) { backup in
                        Button {
                            sheet = .restore(backup)
                        } label: {
                            HStack(spacing: NoopMetrics.space3) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(StrandPalette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(StrandFont.subhead)
                                    Text(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            .frame(minHeight: NoopButtonMetrics.minHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(cloud.activity != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var backupControls: some View {
        if !cloud.hasRecoveryCode, let state = cloud.state {
            NoopButton("Set up a recovery code", systemImage: "key", kind: .secondary) {
                sheet = .setup(state)
            }
            .disabled(cloud.activity != nil)
        }
        Toggle("Automatic backup", isOn: Binding(get: { cloud.automatic }, set: { cloud.setAutomatic($0) }))
            .tint(StrandPalette.accent)
            .disabled(cloud.activity != nil || !cloud.hasRecoveryCode || cloud.backupsDeletionPending)
        help("Pulse checks for changes about once a day while your iPhone is charging. iOS decides when it can run in the background.")
        if let date = cloud.lastSuccess ?? cloud.state?.backups.first?.createdAt {
            let formatted = date.formatted(date: .abbreviated, time: .shortened)
            help("Last successful backup \(formatted)")
        }
        if let retry = cloud.pendingRetry, cloud.automatic {
            let formatted = retry.formatted(date: .abbreviated, time: .shortened)
            help("Next attempt after \(formatted)")
        }
        NoopButton("Back up now", systemImage: "arrow.up.circle", kind: .secondary) {
            Task { await cloud.backupNow() }
        }
        .disabled(cloud.activity != nil || !cloud.hasRecoveryCode || cloud.backupsDeletionPending)
        if cloud.hasRecoveryCode {
            NoopButton("Show recovery code", systemImage: "key", kind: .tertiary) {
                if let code = try? cloud.storedRecoveryCode() { sheet = .recoveryCode(code) }
            }
            .disabled(cloud.activity != nil)
        }
        if cloud.state?.backups.isEmpty == false || cloud.backupsDeletionPending {
            Button("Delete cloud backups", role: .destructive) { confirmDeleteBackups = true }
                .buttonStyle(NoopButtonStyle(.tertiary))
                .disabled(cloud.activity != nil && !cloud.canCancelUpload)
        }
    }

    @ViewBuilder
    private func setupControls(_ state: PulseCloudState) -> some View {
        if cloud.restoreOutcome == .restored {
            help("Make this iPhone the active backup device to protect new activity.")
        } else if !state.backups.isEmpty {
            help("Cloud backups are available. You can restore one below before backing up this iPhone.")
        } else if state.activeDeviceId != nil {
            help("Another installation is the active backup device. Making this iPhone active stops uploads from that installation.")
        } else {
            help("Pulse encrypts your health history and included settings on this iPhone before uploading.")
        }
        NoopButton(state.backups.isEmpty || cloud.restoreOutcome == .restored ? "Set up cloud backup" : "Keep this iPhone’s data",
                   systemImage: "icloud.and.arrow.up", fullWidth: true) {
            if state.backups.isEmpty, state.activeDeviceId == nil {
                sheet = .setup(state)
            } else {
                confirmDeviceChange = true
            }
        }
        .disabled(cloud.activity != nil)
    }

    private var accountActions: some View {
        card("Manage account", icon: "person.badge.shield.checkmark") {
            if cloud.signInMethods == [.google], cloud.emailVerified, !cloud.deletionStarted {
                NoopButton("Add password sign-in", kind: .secondary) { sheet = .addPassword }
                    .disabled(cloud.activity != nil)
            }
            NoopButton("Sign out", kind: .secondary) { Task { await cloud.signOut() } }
                .disabled(cloud.activity != nil && !cloud.canCancelUpload || cloud.hasPendingRestore)
            Button(role: .destructive) {
                sheet = .deleteAccount
            } label: {
                if cloud.deletionStarted {
                    Text("Finish deleting account")
                } else {
                    Text("Delete Pulse account")
                }
            }
            .buttonStyle(NoopButtonStyle(.tertiary))
            .disabled(cloud.activity != nil && !cloud.canCancelUpload || cloud.hasPendingRestore)
        }
    }

    private func activityCard(_ activity: PulseCloudBackupCoordinator.Activity) -> some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if case .uploading(let percent?) = activity {
                    ProgressView(value: Double(percent), total: 100) { Text(activity.title) }
                        .tint(StrandPalette.accent)
                } else {
                    HStack(spacing: NoopMetrics.space3) {
                        ProgressView().tint(StrandPalette.accent)
                        Text(activity.title).font(StrandFont.subhead)
                    }
                }
                if cloud.canCancelUpload {
                    NoopButton("Stop upload", kind: .tertiary) { Task { await cloud.cancelUpload() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func status(_ title: String, icon: String, color: Color) -> some View {
        StrandCard(padding: 18) {
            Label(title, systemImage: icon)
                .font(StrandFont.subhead)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(
        _ title: LocalizedStringKey, icon: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Label(title, systemImage: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func help(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum Sheet: Identifiable {
        case setup(PulseCloudState)
        case restore(PulseCloudBackup)
        case recoveryCode(String)
        case deleteAccount
        case addPassword

        var id: String {
            switch self {
            case .setup: "setup"
            case .restore(let backup): backup.id
            case .recoveryCode: "recovery"
            case .deleteAccount: "delete"
            case .addPassword: "password"
            }
        }
    }
}

private struct PulseCloudSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: PulseCloudBackupCoordinator
    let reviewed: PulseCloudState
    let existingCode: String?
    @State private var newKey = CloudBackupRecoveryKey.generate()
    @State private var saved = false

    private var code: String { existingCode ?? newKey.code }

    var body: some View {
        PulseCloudSheet(title: "Set up cloud backup", busy: cloud.activity != nil) {
            Text("Save this recovery code somewhere you can reach if you lose this iPhone. It unlocks your backup. Pulse can’t reset the code or recover your backup without it.")
            if existingCode == nil, !reviewed.backups.isEmpty {
                Text("This code will unlock new backups. To restore an earlier backup, use its original recovery code.")
            }
            PulseCloudRecoveryCode(code: code)
            Toggle("I saved my recovery code", isOn: $saved).tint(StrandPalette.accent)
            NoopButton("Enable automatic backup", systemImage: "lock.icloud", fullWidth: true) {
                Task {
                    guard let key = try? CloudBackupRecoveryKey(code: code) else { return }
                    if await cloud.enableBackup(using: key, reviewed: reviewed) {
                        dismiss()
                        await cloud.runAutomaticBackupIfDue()
                    }
                }
            }
            .disabled(!saved || cloud.activity != nil)
            PulseCloudSheetStatus(cloud: cloud)
        }
    }
}

private struct PulseCloudRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: PulseCloudBackupCoordinator
    let backup: PulseCloudBackup
    @State private var code = ""
    @State private var confirm = false
    @State private var invalidCode = false

    var body: some View {
        PulseCloudSheet(title: "Restore cloud backup", busy: cloud.activity != nil) {
            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(StrandFont.headline)
            Text("Enter the recovery code used for this backup. Pulse verifies the backup before replacing your local history.")
            Text("Restored workouts stay in Pulse. New workouts can still be written to Apple Health.")
            SecureField("Recovery code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .pulseCloudField()
            if cloud.hasRecoveryCode {
                Button("Use saved recovery code") {
                    if let saved = try? cloud.storedRecoveryCode() { code = saved }
                }
                .buttonStyle(NoopButtonStyle(.tertiary))
                .disabled(cloud.activity != nil)
            }
            if invalidCode {
                Text("Check the recovery code and try again.").foregroundStyle(StrandPalette.statusWarning)
            }
            NoopButton("Prepare restore", kind: .secondary, fullWidth: true) {
                invalidCode = (try? CloudBackupRecoveryKey(code: code)) == nil
                confirm = !invalidCode
            }
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.activity != nil)
            PulseCloudSheetStatus(cloud: cloud)
        }
        .alert("Replace data on this iPhone?", isPresented: $confirm) {
            Button("Prepare restore", role: .destructive) {
                Task {
                    guard let key = try? CloudBackupRecoveryKey(code: code) else { return }
                    let staged = await cloud.restore(backup, using: key)
                    if staged || cloud.hasPendingRestore { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pulse will replace your local history and included settings the next time you fully quit and reopen it.")
        }
    }
}

private struct PulseCloudDeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: PulseCloudBackupCoordinator
    @State private var password = ""

    private var canUseGoogle: Bool { cloud.signInMethods.contains(.google) }
    private var canUsePassword: Bool { !canUseGoogle || cloud.signInMethods.contains(.password) }
    private var busy: Bool { cloud.activity != nil && !cloud.canCancelUpload }

    var body: some View {
        PulseCloudSheet(title: "Delete Pulse account", busy: busy) {
            Text("This permanently deletes your Pulse account and its cloud backups. Your data stays on this iPhone.")
            if canUsePassword {
                SecureField("Confirm your password", text: $password)
                    .textContentType(.password)
                    .pulseCloudField()
                NoopButton("Delete Pulse account", kind: .destructive, fullWidth: true) {
                    let input = password
                    password = ""
                    Task { if await cloud.deleteAccount(using: .password, password: input) { dismiss() } }
                }
                .disabled(password.isEmpty || busy)
            }
            if canUseGoogle {
                NoopButton("Confirm with Google and delete", kind: .destructive, fullWidth: true) {
                    password = ""
                    Task { if await cloud.deleteAccount(using: .google) { dismiss() } }
                }
                .disabled(busy)
            }
            PulseCloudSheetStatus(cloud: cloud)
        }
    }
}

private struct PulseCloudAddPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: PulseCloudBackupCoordinator
    @State private var password = ""

    var body: some View {
        PulseCloudSheet(title: "Add password sign-in", busy: cloud.activity != nil) {
            Text("Confirm your Google account to add a password for the same Pulse account and backups.")
            SecureField("New password", text: $password)
                .textContentType(.newPassword)
                .pulseCloudField()
            NoopButton("Confirm with Google", fullWidth: true) {
                let input = password
                password = ""
                Task { if await cloud.addPassword(input) { dismiss() } }
            }
            .disabled(password.isEmpty || cloud.activity != nil)
            PulseCloudSheetStatus(cloud: cloud)
        }
    }
}

private struct PulseCloudRecoverySheet: View {
    let code: String

    var body: some View {
        PulseCloudSheet(title: "Backup recovery code") {
            Text("Keep this code somewhere you can access if you lose this iPhone. Anyone with the code and a copy of your encrypted backup can open it.")
            PulseCloudRecoveryCode(code: code)
        }
    }
}

private struct PulseCloudRecoveryCode: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Text(code)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NoopMetrics.space4)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .privacySensitive()
        NoopButton(copied ? "Copied" : "Copy recovery code", systemImage: "doc.on.doc", kind: .secondary) {
            UIPasteboard.general.setItems([["public.utf8-plain-text": code]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
            copied = true
        }
    }
}

private struct PulseCloudSheetStatus: View {
    @ObservedObject var cloud: PulseCloudBackupCoordinator

    var body: some View {
        if let activity = cloud.activity {
            ProgressView(activity.title).tint(StrandPalette.accent)
        }
        if let error = cloud.errorMessage {
            Text(error).foregroundStyle(StrandPalette.statusWarning)
        }
    }
}

private struct PulseCloudSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    var busy = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    content()
                }
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PulseDashboardStyle.pagePadding)
            }
            .background(PulsePageBackground().ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }
}

private extension View {
    func pulseCloudField() -> some View {
        self
            .font(StrandFont.body)
            .padding(NoopMetrics.space3)
            .frame(minHeight: NoopButtonMetrics.minHitTarget)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(StrandPalette.textPrimary)
    }
}
