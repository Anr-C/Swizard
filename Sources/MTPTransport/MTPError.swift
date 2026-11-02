import Foundation

public enum MTPError: LocalizedError, Equatable {
    case deviceNotFound
    case connectionFailed(String)
    case storageNotFound
    case installFolderNotFound(String)
    case transferFailed(String)
    case cancelled
    case noStorage

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: "未找到 MTP 设备"
        case .connectionFailed(let detail): "MTP 连接失败：\(detail)"
        case .storageNotFound: "设备上没有可用存储空间"
        case .installFolderNotFound(let name): "设备上找不到安装目录“\(name)”"
        case .transferFailed(let detail): "MTP 传输失败：\(detail)"
        case .cancelled: "传输已取消"
        case .noStorage: "设备没有存储空间"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .transferFailed: return true
        case .connectionFailed: return true
        default: return false
        }
    }
}
