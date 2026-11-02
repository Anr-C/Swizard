import Foundation

public enum InstallError: LocalizedError {
    case fileNotFound(String)
    case fileReadFailed(String, any Error)
    case cancelled
    case connectionLost

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let name): "找不到文件：\(name)"
        case .fileReadFailed(let name, let error): "读取 \(name) 失败：\(error.localizedDescription)"
        case .cancelled: "安装已取消"
        case .connectionLost: "与 Switch 的连接已断开"
        }
    }
}
