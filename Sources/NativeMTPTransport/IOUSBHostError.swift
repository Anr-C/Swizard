import Foundation

/// Errors for the IOUSBHost adapter layer.
public enum IOUSBHostError: LocalizedError, Equatable {
    case deviceNotFound
    case openFailed(String)
    case claimFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case seizeRejected

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: "通过 IOUSBHost 未找到 Nintendo Switch"
        case .openFailed(let d): "无法打开 USB 设备：\(d)"
        case .claimFailed(let d): "无法接管 USB 接口：\(d)"
        case .readFailed(let d): "USB 读取失败：\(d)"
        case .writeFailed(let d): "USB 写入失败：\(d)"
        case .seizeRejected: "macOS 拒绝释放 USB 设备。请拔下 Switch 后重新连接。"
        }
    }
}
