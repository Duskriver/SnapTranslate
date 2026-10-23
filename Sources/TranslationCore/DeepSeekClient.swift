import Foundation

public struct DeepSeekClient: Sendable {
    private let makeSession: @Sendable () -> URLSession
    private let updateInterval: Duration

    public init() {
        makeSession = { URLSession(configuration: Self.sessionConfiguration()) }
        updateInterval = .milliseconds(90)
    }

    // A session factory lets tests exercise streaming and cancellation without a real API key.
    init(updateInterval: Duration = .milliseconds(90), makeSession: @escaping @Sendable () -> URLSession) {
        self.updateInterval = updateInterval
        self.makeSession = makeSession
    }

    /// Calls onDelta with new text only, coalesced about every 90 ms. Remaining
    /// text is flushed on completion or failure; cancellation never flushes it.
    public func translate(
        imageData: Data,
        mimeType: String,
        apiKey: String,
        targetLanguage: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.makeRequest(
            imageData: imageData, mimeType: mimeType,
            apiKey: apiKey, targetLanguage: targetLanguage
        )
        let session = makeSession()
        // No session, in-flight task, cookie store, or HTTP cache survives this translation.
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            do {
                let bodyDelegate = (request.httpBodyStream as? RequestBodyStream).map {
                    RequestBodyDelegate(body: $0.body)
                }
                let (bytes, response) = try await session.bytes(for: request, delegate: bodyDelegate)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else {
                    throw TranslationError.invalidResponse
                }
                guard (200..<300).contains(response.statusCode) else {
                    // Do not buffer or expose a server body that could echo private input.
                    throw Self.error(forHTTPStatus: response.statusCode)
                }
                guard response.mimeType?.lowercased() == "text/event-stream" else {
                    throw TranslationError.invalidResponse
                }

                var parser = SSEParser()
                var stream = TranslationStream()
                let clock = ContinuousClock()
                var lastUpdate = clock.now
                do {
                    for try await byte in bytes {
                        guard let payload = try parser.push(byte) else { continue }
                        try Task.checkCancellation()
                        try stream.consume(payload)
                        if stream.hasPendingText,
                           lastUpdate.duration(to: clock.now) >= updateInterval {
                            await onDelta(stream.takePendingText())
                            lastUpdate = clock.now
                        }
                        if stream.isDone { break }
                    }
                    try Task.checkCancellation()
                    if stream.hasPendingText {
                        await onDelta(stream.takePendingText())
                    }
                    try Task.checkCancellation()
                    return try stream.completedText()
                } catch {
                    // Preserve the last partial text on an interrupted stream, but never
                    // issue a late UI update after the caller has cancelled or closed it.
                    if !Task.isCancelled, stream.hasPendingText {
                        await onDelta(stream.takePendingText())
                    }
                    if !Task.isCancelled, !stream.text.isEmpty,
                       let urlError = error as? URLError, urlError.code != .cancelled {
                        throw TranslationError.incompleteStream
                    }
                    throw error
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled { throw CancellationError() }
                    if urlError.code == .timedOut { throw TranslationError.timedOut }
                    throw TranslationError.networkUnavailable
                }
                throw error
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeRequest(
        imageData: Data,
        mimeType: String,
        apiKey: String,
        targetLanguage: String
    ) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        guard key.utf8.count <= 1_024,
              key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw TranslationError.invalidAPIKey
        }
        guard !imageData.isEmpty,
              ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mimeType) else {
            throw TranslationError.invalidImage
        }
        guard imageData.count <= 10 * 1_024 * 1_024 else { throw TranslationError.imageTooLarge }
        let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty, language.count <= 128 else {
            throw TranslationError.invalidTargetLanguage
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body = try CompletionRequestBody(imageData: imageData, mimeType: mimeType, language: language)
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = RequestBodyStream(body: body)
        return request
    }

    static func error(forHTTPStatus status: Int) -> TranslationError {
        switch status {
        case 401, 403: .unauthorized
        case 402: .insufficientBalance
        case 408, 504: .timedOut
        case 429: .rateLimited
        case 500...599: .serverUnavailable
        default: .rejectedRequest(status)
        }
    }
}
