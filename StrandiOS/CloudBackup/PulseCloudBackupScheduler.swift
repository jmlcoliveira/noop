import BackgroundTasks
import Foundation

@MainActor
enum PulseCloudBackupScheduler {
    private static let taskIdentifier = BackgroundTaskIdentifier.identifier("pulsecloudbackup")

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletion(task)
            let work = Task { @MainActor in
                await PulseCloudBackupCoordinator.shared.runAutomaticBackupIfDue()
                completion.finish(success: !Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()
                completion.finish(success: false)
            }
        }
    }

    static func schedule(after date: Date) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = date
        cancel()
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(_ task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
}
