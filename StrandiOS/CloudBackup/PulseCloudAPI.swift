import Foundation

struct PulseCloudDevice: Codable, Sendable {
    let id: String
    let key: String
}

struct PulseCloudBackup: Decodable, Identifiable, Sendable {
    let id: String
    let size: Int64
    let sha256: String
    let createdAt: Date
}

struct PulseCloudState: Decodable, Sendable {
    let activeDeviceId: String?
    let generation: Int
    let backups: [PulseCloudBackup]
    let maxBackupBytes: Int64
}

struct PulseCloudMultipartStatus: Decodable, Sendable {
    let partSize: Int64
    let totalParts: Int
    let receivedParts: [Int]
    let backup: PulseCloudBackup?
}

enum PulseCloudAPIError: LocalizedError {
    case service(status: Int, code: String?)
    case invalidResponse
    case wifiUnavailable
    case tooLarge
    case deviceConflict
    case recoveryKeyMissing

    var errorDescription: String? {
        switch self {
        case .wifiUnavailable:
            String(localized: "Connect to Wi-Fi or change the Wi-Fi only setting.")
        case .tooLarge, .service(413, _):
            String(localized: "This backup exceeds the cloud backup size limit.")
        case .deviceConflict, .service(409, "device_conflict"):
            String(localized: "This iPhone is no longer the active backup device. Review the backup settings to make it active again.")
        case .recoveryKeyMissing:
            String(localized: "Enter your recovery code on this iPhone to resume backups.")
        case .invalidResponse:
            String(localized: "Pulse received an unexpected response from the backup service.")
        case .service(401, _):
            String(localized: "The backup service couldn’t verify your session. Try again or sign in again.")
        case .service(403, "email_not_verified"):
            String(localized: "Verify your email address before using cloud backup.")
        case .service(403, _):
            String(localized: "Cloud backup access hasn’t been granted for this account.")
        case .service(404, _):
            String(localized: "This backup is no longer available.")
        case .service(410, "account_deleted"):
            String(localized: "Cloud data for this account was deleted.")
        case .service(429, _):
            String(localized: "The backup service is busy. Try again in a few minutes.")
        case .service:
            String(localized: "The backup service couldn’t complete the request. Try again.")
        }
    }

    var needsDeviceReview: Bool {
        switch self {
        case .deviceConflict, .service(409, "device_conflict"): true
        default: false
        }
    }

    var shouldPauseAutomatic: Bool {
        switch self {
        case .service(403, _), .service(410, "account_deleted"), .recoveryKeyMissing: true
        default: false
        }
    }

    var shouldDiscardUpload: Bool {
        guard case let .service(status, code) = self else { return false }
        return PulseCloudBackupPolicy.shouldDiscardStagedUpload(httpStatus: status, code: code)
    }
}

struct PulseCloudAPI: Sendable {
    private static let baseURL = URL(string: "https://pulse.joliveira.xyz/v1/")!
    private static let controlSession = makeSession(wifiOnly: false)
    private static let wifiSession = makeSession(wifiOnly: true)

    func state(token: String) async throws -> PulseCloudState {
        try await decode(request("state", token: token))
    }

    func claim(device: PulseCloudDevice, generation: Int, token: String) async throws -> PulseCloudState {
        var request = request("device/claim", method: "POST", token: token, device: device)
        request.httpBody = try JSONEncoder().encode(Claim(expectedGeneration: generation))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(request)
    }

    func uploadRequest(
        id: String, size: Int64, sha256: String, device: PulseCloudDevice, generation: Int,
        token: String
    ) -> URLRequest {
        put("backups/\(id)", size: size, sha256: sha256, device: device, generation: generation, token: token)
    }

    func startMultipart(_ upload: PulseCloudPendingUpload, device: PulseCloudDevice, token: String) async throws
        -> PulseCloudMultipartStatus {
        var request = request("backups/\(upload.id)/parts", method: "POST", token: token, device: device,
                              generation: upload.generation)
        request.httpBody = try JSONEncoder().encode(Multipart(size: upload.size, sha256: upload.sha256))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(request)
    }

    func partRequest(
        _ part: PulseCloudPendingUpload.Part, upload: PulseCloudPendingUpload, device: PulseCloudDevice, token: String
    ) -> URLRequest {
        put("backups/\(upload.id)/parts/\(part.number)", size: part.size, sha256: part.sha256, device: device,
            generation: upload.generation, token: token)
    }

    func completeMultipartRequest(_ upload: PulseCloudPendingUpload, device: PulseCloudDevice, token: String) -> URLRequest {
        request("backups/\(upload.id)/parts/complete", method: "POST", token: token, device: device,
                generation: upload.generation)
    }

    func abortMultipart(id: String, generation: Int, device: PulseCloudDevice, token: String) async throws {
        let request = request("backups/\(id)/parts", method: "DELETE", token: token, device: device, generation: generation)
        let (body, response) = try await Self.controlSession.data(for: request)
        try Self.validate(response, body: body)
    }

    private func put(
        _ path: String, size: Int64, sha256: String, device: PulseCloudDevice, generation: Int, token: String
    ) -> URLRequest {
        var request = request(path, method: "PUT", token: token, device: device, generation: generation)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue(sha256, forHTTPHeaderField: "X-Pulse-SHA256")
        return request
    }

    func download(
        _ backup: PulseCloudBackup, into directory: URL, maxBytes: Int64, token: String, wifiOnly: Bool
    ) async throws -> URL {
        guard UUID(uuidString: backup.id) != nil,
              backup.size > 0, backup.size <= maxBytes else { throw PulseCloudAPIError.invalidResponse }
        let request = request("backups/\(backup.id)", token: token)
        let (temporary, response) = try await (wifiOnly ? Self.wifiSession : Self.controlSession).download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response, body: Data())
        let byteCount = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard byteCount.map(Int64.init) == backup.size else { throw PulseCloudAPIError.invalidResponse }
        let destination = directory.appendingPathComponent("download.pulsebackup")
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: destination.path)
        return destination
    }

    func deleteBackups(device: PulseCloudDevice, generation: Int, token: String) async throws -> Int {
        let request = request("backups", method: "DELETE", token: token, device: device, generation: generation)
        let (body, response) = try await Self.controlSession.data(for: request)
        try Self.validate(response, body: body)
        guard let response = response as? HTTPURLResponse,
              let value = response.value(forHTTPHeaderField: "X-Pulse-Generation"),
              let updated = Int(value), updated > generation else { throw PulseCloudAPIError.invalidResponse }
        return updated
    }

    func deleteAccount(token: String) async throws {
        let (body, response) = try await Self.controlSession.data(for: request("account", method: "DELETE", token: token))
        try Self.validate(response, body: body)
    }

    static func backupResponse(_ response: URLResponse?, body: Data) throws -> PulseCloudBackup {
        try validate(response, body: body)
        return try decoder().decode(PulseCloudBackup.self, from: body)
    }

    static func validatePartResponse(_ response: URLResponse?, body: Data) throws {
        try validate(response, body: body)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw PulseCloudAPIError.invalidResponse }
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (body, response) = try await Self.controlSession.data(for: request)
        try Self.validate(response, body: body)
        return try Self.decoder().decode(T.self, from: body)
    }

    private func request(
        _ path: String, method: String = "GET", token: String, device: PulseCloudDevice? = nil, generation: Int? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!.absoluteURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let device {
            request.setValue(device.id, forHTTPHeaderField: "X-Pulse-Device-ID")
            request.setValue(device.key, forHTTPHeaderField: "X-Pulse-Device-Key")
        }
        if let generation {
            request.setValue(String(generation), forHTTPHeaderField: "X-Pulse-Generation")
        }
        return request
    }

    private static func validate(_ response: URLResponse?, body: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw PulseCloudAPIError.invalidResponse }
        guard 200..<300 ~= response.statusCode else {
            let code = (try? JSONDecoder().decode(ServiceError.self, from: body))?.error
            throw PulseCloudAPIError.service(status: response.statusCode, code: code)
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let container = try input.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = .withInternetDateTime
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid backup timestamp")
        }
        return decoder
    }

    private static func makeSession(wifiOnly: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.timeoutIntervalForRequest = 25
        return URLSession(configuration: configuration)
    }

    private struct Claim: Encodable { let expectedGeneration: Int }
    private struct Multipart: Encodable { let size: Int64; let sha256: String }
    private struct ServiceError: Decodable { let error: String }
}
