import Foundation

enum PulseCloudUploadReceipt {
    case backup(PulseCloudBackup)
    case part
}

/// Keeps OS-owned uploads recoverable when Pulse is suspended or relaunched for a session callback.
final class PulseCloudTransfers: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let prefix = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".pulsecloud.upload"
    private static let unrestrictedIdentifier = prefix + ".any"
    private static let wifiIdentifier = prefix + ".wifi"

    @MainActor
    static let shared = PulseCloudTransfers()

    @MainActor
    private var responses: [String: Data] = [:]
    @MainActor
    private var completionHandlers: [String: () -> Void] = [:]
    @MainActor
    private var endedEvents: Set<String> = []
    @MainActor
    private var followUps: [String: Int] = [:]

    @MainActor
    private lazy var unrestricted = makeSession(identifier: Self.unrestrictedIdentifier, wifiOnly: false)
    @MainActor
    private lazy var wifi = makeSession(identifier: Self.wifiIdentifier, wifiOnly: true)

    @MainActor
    func resumeEvents(for identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.unrestrictedIdentifier || identifier == Self.wifiIdentifier else {
            completion()
            return
        }
        completionHandlers[identifier] = completion
        _ = identifier == Self.wifiIdentifier ? wifi : unrestricted
    }

    @MainActor
    func enqueue(_ request: URLRequest, file: URL, upload: PulseCloudUploadTask, wifiOnly: Bool) {
        let task = (wifiOnly ? wifi : unrestricted).uploadTask(with: request, fromFile: file)
        task.taskDescription = upload.description
        task.resume()
    }

    @MainActor
    func contains(id: String) async -> Bool {
        if await wifi.allTasks.contains(where: { isPending($0, id: id) }) { return true }
        return await unrestricted.allTasks.contains(where: { isPending($0, id: id) })
    }

    @MainActor
    func cancel(id: String) async {
        for session in [wifi, unrestricted] {
            for task in await session.allTasks where isPending(task, id: id) {
                task.cancel()
            }
        }
    }

    private func makeSession(identifier: String, wifiOnly: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.httpMaximumConnectionsPerHost = 2
        // A queued request carries a short-lived Firebase token. Fail promptly enough to re-sign
        // on the next eligible retry instead of leaving an unusable upload queued for days.
        configuration.timeoutIntervalForResource = 40 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    private func uploadTask(_ task: URLSessionTask) -> PulseCloudUploadTask? {
        PulseCloudUploadTask(description: task.taskDescription, url: task.originalRequest?.url)
    }

    private func isPending(_ task: URLSessionTask, id: String) -> Bool {
        (task.state == .running || task.state == .suspended) && uploadTask(task)?.backupID == id
    }

    private func responseKey(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session.configuration.identifier ?? ""):\(task.taskIdentifier)"
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            let key = responseKey(session, dataTask)
            if responses[key, default: Data()].count + data.count <= 32 * 1024 {
                responses[key, default: Data()].append(data)
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard let upload = uploadTask(task), totalBytesExpectedToSend > 0 else { return }
        MainActor.assumeIsolated {
            PulseCloudBackupCoordinator.shared.uploadProgress(
                upload, fraction: Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            let body = responses.removeValue(forKey: responseKey(session, task)) ?? Data()
            guard let upload = uploadTask(task) else { return }
            let result = Result<PulseCloudUploadReceipt, any Error> {
                if let error { throw error }
                if case .part = upload.kind {
                    try PulseCloudAPI.validatePartResponse(task.response, body: body)
                    return .part
                }
                return .backup(try PulseCloudAPI.backupResponse(task.response, body: body))
            }
            let coordinator = PulseCloudBackupCoordinator.shared
            if let work = coordinator.uploadCompleted(upload, result: result),
               let identifier = session.configuration.identifier {
                followUps[identifier, default: 0] += 1
                Task {
                    await work()
                    followUps[identifier, default: 0] -= 1
                    if followUps[identifier] == 0 { followUps.removeValue(forKey: identifier) }
                    finishEventsIfReady(identifier)
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            if let identifier = session.configuration.identifier, completionHandlers[identifier] != nil {
                endedEvents.insert(identifier)
                finishEventsIfReady(identifier)
            }
        }
    }

    @MainActor
    private func finishEventsIfReady(_ identifier: String) {
        guard followUps[identifier] == nil, endedEvents.remove(identifier) != nil else { return }
        completionHandlers.removeValue(forKey: identifier)?()
    }
}
