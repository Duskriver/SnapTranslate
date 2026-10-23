import Foundation
import Testing
@testable import TranslationCore

@Suite(.serialized)
struct RequestEncodingTests {
    @Test(arguments: [1, 2, 3, 49_151, 49_152, 49_153, 49_154, 98_304, 98_305, 10 * 1_024 * 1_024])
    func imageBytesSurviveChunkBoundariesAndNonzeroDataIndices(count: Int) throws {
        // Exercise all byte values, Base64 padding, and Data slices whose indices
        // do not start at zero. Compare with Foundation's whole-image encoder.
        let storage = Data((0..<(count + 7)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let image = storage[7...]
        #expect(image.startIndex == 7)
        let body = try requestBody(image: image)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        let imageURL = try #require(content.last?["image_url"] as? [String: String])
        let url = try #require(imageURL["url"])
        let prefix = "data:image/png;base64,"
        #expect(url == prefix + image.base64EncodedString())
        #expect(Data(base64Encoded: String(url.dropFirst(prefix.count))) == image)
        #expect(imageURL["detail"] == "original")
    }

    @Test(arguments: ["image/png", "image/jpeg", "image/webp", "image/gif"])
    func dynamicTextRemainsJSONEscapedWithoutChangingRequestShape(mimeType: String) throws {
        let language = "中文\"\\/\n\t\u{0}\u{1}\u{1f}\u{2028}e\u{301}🌍\"}],\"model\":\"injected"
        let body = try requestBody(image: Data([0xFB, 0xFF]), mimeType: mimeType, language: language)
        #expect(Set(body.keys) == ["model", "stream", "thinking", "max_tokens", "messages"])
        #expect(body["model"] as? String == "deepseek-flash")
        #expect(body["stream"] as? Bool == true)
        #expect(body["thinking"] as? [String: String] == ["type": "disabled"])
        #expect(body["max_tokens"] as? Int == 16_384)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["text"] as? String == "请将截图中所有可辨认文字翻译成\(language)。保持原有阅读顺序、段落和列表结构；尽量保留表格关系。保留无需翻译的代码、网址和专有名词。无法辨认的文字用［无法辨认］标记。若没有文字，只输出［未发现可翻译文字］。")
        #expect(content[1]["image_url"] as? [String: String] == [
            "detail": "original", "url": "data:\(mimeType);base64,+/8=",
        ])
    }

    @Test func invalidInputsAreRejectedBeforeBodyAssembly() {
        #expect(throws: TranslationError.invalidImage) {
            try requestBody(image: Data([1]), mimeType: "image/png\"},\"injected\":true")
        }
        #expect(throws: TranslationError.imageTooLarge) {
            try requestBody(image: Data(repeating: 0, count: 10 * 1_024 * 1_024 + 1))
        }
        #expect(throws: TranslationError.invalidTargetLanguage) {
            try requestBody(image: Data([1]), language: String(repeating: "a", count: 129))
        }
    }

    @Test func cancelledTaskDoesNotConstructRequestBody() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DeepSeekClient.makeRequest(
                imageData: Data([1]), mimeType: "image/png", apiKey: "key", targetLanguage: "中文"
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func requestBody(image: Data, mimeType: String = "image/png", language: String = "中文") throws -> [String: Any] {
        let request = try DeepSeekClient.makeRequest(
            imageData: image, mimeType: mimeType, apiKey: "key", targetLanguage: language
        )
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
