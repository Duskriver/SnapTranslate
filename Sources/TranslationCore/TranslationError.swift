import Foundation

public enum TranslationError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidImage
    case imageTooLarge
    case invalidTargetLanguage
    case unauthorized
    case insufficientBalance
    case rateLimited
    case serverUnavailable
    case rejectedRequest(Int)
    case invalidResponse
    case malformedStream
    case incompleteStream
    case emptyTranslation
    case outputTooLarge
    case outputTruncated
    case contentFiltered
    case networkUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先在设置中填写 DeepSeek API Key。"
        case .invalidAPIKey: "API Key 格式不正确，请重新粘贴。"
        case .invalidImage: "截图为空或图片格式不受支持，请重新截图。"
        case .imageTooLarge: "截图超过 10 MB，请缩小截图范围后重试。"
        case .invalidTargetLanguage: "目标语言无效，请检查设置。"
        case .unauthorized: "DeepSeek API Key 无效或没有访问权限，请检查设置。"
        case .insufficientBalance: "DeepSeek 账户余额不足，请充值后重试。"
        case .rateLimited: "DeepSeek 请求过于频繁，请稍后重试。"
        case .serverUnavailable: "DeepSeek 服务暂时不可用，请稍后重试。"
        case .rejectedRequest(let status): "DeepSeek 未接受请求（HTTP \(status)），请缩小截图范围后重试。"
        case .invalidResponse: "DeepSeek 返回了无法识别的响应，请重试。"
        case .malformedStream: "DeepSeek 返回的数据格式异常，请重试。"
        case .incompleteStream: "连接在翻译完成前中断，当前译文可能不完整，请重试。"
        case .emptyTranslation: "DeepSeek 没有返回译文，请确认截图中包含清晰文字后重试。"
        case .outputTooLarge: "译文超过了显示上限，请缩小截图范围后重试。"
        case .outputTruncated: "译文达到长度限制，当前结果不完整，请分区域截图。"
        case .contentFiltered: "DeepSeek 未能完整翻译这张截图，请调整截图范围后重试。"
        case .networkUnavailable: "无法连接 DeepSeek，请检查网络后重试。"
        case .timedOut: "DeepSeek 响应超时，请稍后重试。"
        }
    }
}
