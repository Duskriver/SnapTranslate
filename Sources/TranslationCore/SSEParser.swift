import Foundation

/// Incremental SSE framing. UTF-8 is decoded only after a complete event has arrived.
struct SSEParser {
    private var line = Data()
    private var event = Data()
    private var hasData = false
    private var skipLineFeed = false
    private var firstLine = true
    private let maximumEventBytes: Int

    init(maximumEventBytes: Int = 256 * 1_024) {
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func push(_ byte: UInt8) throws -> Data? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 { return nil }
        }
        if byte == 13 {
            skipLineFeed = true
            return try finishLine()
        }
        if byte == 10 { return try finishLine() }
        guard line.count < maximumEventBytes else { throw TranslationError.outputTooLarge }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }

        if line.isEmpty {
            guard hasData else { return nil }
            let payload = event
            event = Data()
            hasData = false
            return payload
        }

        // Other fields and keepalive comments intentionally carry no application state.
        let separator = line.firstIndex(of: 58)
        let field = separator.map { line[..<$0] } ?? line[...]
        guard field.elementsEqual([100, 97, 116, 97]) else { return nil } // "data"
        var value = separator.map { line[line.index(after: $0)...] } ?? Data.SubSequence()
        if value.first == 32 { value = value.dropFirst() }
        let additionalBytes = value.count + (hasData ? 1 : 0)
        guard event.count + additionalBytes <= maximumEventBytes else {
            throw TranslationError.outputTooLarge
        }
        if hasData { event.append(10) }
        event.append(contentsOf: value)
        hasData = true
        return nil
    }
}

/// Decodes only visible text. Reasoning, usage metadata, and other choices are ignored.
struct TranslationStream {
    private(set) var text = ""
    private(set) var isDone = false
    private(set) var byteCount = 0
    private var finishReason: String?
    private let maximumOutputBytes: Int
    private let decoder = JSONDecoder()

    init(maximumOutputBytes: Int = 1_024 * 1_024) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    mutating func consume(_ payload: Data) throws {
        guard !isDone, !payload.isEmpty else { return }
        if payload.elementsEqual("[DONE]".utf8) {
            isDone = true
            return
        }
        let chunk: StreamChunk
        do { chunk = try decoder.decode(StreamChunk.self, from: payload) }
        catch { throw TranslationError.malformedStream }
        if chunk.error != nil { throw TranslationError.serverUnavailable }
        guard let choices = chunk.choices else { throw TranslationError.malformedStream }
        guard let choice = choices.first(where: { $0.index == 0 }) else { return }
        if let content = choice.delta?.content, !content.isEmpty {
            let additionalBytes = content.utf8.count
            guard byteCount + additionalBytes <= maximumOutputBytes else {
                throw TranslationError.outputTooLarge
            }
            text.append(content)
            byteCount += additionalBytes
        }
        if let reason = choice.finishReason { finishReason = reason }
    }

    func completedText() throws -> String {
        guard isDone else { throw TranslationError.incompleteStream }
        switch finishReason {
        case "stop": break
        case "length": throw TranslationError.outputTruncated
        case "content_filter": throw TranslationError.contentFiltered
        case "insufficient_system_resource": throw TranslationError.serverUnavailable
        case "aborted": throw TranslationError.incompleteStream
        default: throw TranslationError.incompleteStream
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return text
    }
}

private struct StreamChunk: Decodable {
    let choices: [Choice]?
    let error: ServerError?

    struct Choice: Decodable {
        let index: Int
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }

    struct ServerError: Decodable {}
}
