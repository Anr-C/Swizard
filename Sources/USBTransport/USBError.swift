import Foundation

public enum USBError: LocalizedError, Equatable {
    case deviceNotFound
    case initializationFailed(Int32)
    case claimFailed(Int32)
    case transferFailed(Int32)
    case timeout
    case disconnected
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: "未找到 Nintendo Switch"
        case .initializationFailed(let code): "USB 初始化失败（错误代码：\(code)）。请检查 libusb 是否已安装。"
        case .claimFailed(let code): "无法接管 USB 接口（错误代码：\(code)）"
        case .transferFailed(let code): "USB 传输失败（错误代码：\(code)）"
        case .timeout: "USB 传输超时"
        case .disconnected: "Switch 已断开连接"
        case .notConnected: "尚未连接到 Switch"
        }
    }

    /// Whether this error is transient and the operation should be retried.
    public var isRetryable: Bool {
        switch self {
        case .timeout: return true
        case .transferFailed(let code):
            // PIPE (-9), OVERFLOW (-8), INTERRUPTED (-10)
            return code == -9 || code == -8 || code == -10
        case .disconnected, .deviceNotFound, .claimFailed, .notConnected, .initializationFailed:
            return false
        }
    }

    /// Whether this error indicates an endpoint stall requiring libusb_clear_halt.
    public var requiresStallRecovery: Bool {
        if case .transferFailed(let code) = self { return code == -9 }
        return false
    }
}
