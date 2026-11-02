import Foundation

public enum FTPUploadError: LocalizedError, Equatable {
    case connectionFailed(String)
    case transferFailed(String)
    case cancelled
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let d): "FTP 连接失败：\(d)"
        case .transferFailed(let d): "FTP 传输失败：\(d)"
        case .cancelled: "FTP 传输已取消"
        case .invalidFile(let d): "文件无效：\(d)"
        }
    }
}
