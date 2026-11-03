import Foundation

public protocol RCMInjector: Sendable {
    func inject(payloadAt url: URL) async throws
}

public enum RCMInjectionError: LocalizedError {
    case emptyPayload
    case payloadReadFailed(String)
    case payloadTooLarge
    case missingIntermezzo
    case intermezzoReadFailed(String)
    case deviceNotFound
    case host(String)
    case invalidDeviceID
    case deviceIDUnavailable
    case triggerUnconfirmed(String)
    case unexpectedControlResponse(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyPayload: "payload 文件为空。"
        case let .payloadReadFailed(reason): "读取 payload 失败：\(reason)"
        case .payloadTooLarge: "payload 超过 RCM 允许的大小。"
        case .missingIntermezzo: "应用缺少 intermezzo.bin。"
        case let .intermezzoReadFailed(reason): "读取 intermezzo.bin 失败：\(reason)"
        case .deviceNotFound: "未找到 RCM 设备。"
        case let .host(reason): "RCM IOKit 操作失败：\(reason)"
        case .invalidDeviceID: "RCM 设备 ID 无效，请重新进入 RCM 模式。"
        case .deviceIDUnavailable: "RCM 设备未返回 ID。上次注入可能留下了无效会话；请将设备完全关机，重新进入 RCM 并重新插拔 USB 后重试。若首次尝试仍超时，请检查线缆和端口。"
        case let .triggerUnconfirmed(reason): "payload 已发送，但触发请求\(reason)；请在设备上确认是否启动。"
        case let .unexpectedControlResponse(result): "RCM 触发请求意外成功（返回 \(result)），注入可能失败。"
        }
    }
}

/// CrystalRCM-style legacy IOKit RCM injection sequence.
public final class FuseeGeleeInjector: RCMInjector, @unchecked Sendable {
    private static let payloadAddress: UInt32 = 0x40010000
    private static let payloadStart: UInt32 = 0x40010e40
    private static let sprayStart: UInt32 = 0x40014e40
    private static let sprayEnd: UInt32 = 0x40017000
    private static let maxLength = 0x30298
    private static let chunkSize = 0x1000
    static let maxPayloadFileSize = (maxLength / chunkSize * chunkSize)
        - Int(sprayEnd - payloadAddress) + Int(sprayStart - payloadStart)

    public init() {}

    public func inject(payloadAt url: URL) async throws {
        guard url.isFileURL else { throw RCMInjectionError.payloadReadFailed("不是本地文件") }
        let fileSize: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw RCMInjectionError.payloadReadFailed("无法获取文件大小")
            }
            fileSize = size.intValue
        } catch let error as RCMInjectionError {
            throw error
        } catch {
            throw RCMInjectionError.payloadReadFailed(error.localizedDescription)
        }
        guard fileSize > 0 else { throw RCMInjectionError.emptyPayload }
        guard fileSize <= Self.maxPayloadFileSize else { throw RCMInjectionError.payloadTooLarge }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw RCMInjectionError.payloadReadFailed(error.localizedDescription) }
        guard !data.isEmpty else { throw RCMInjectionError.emptyPayload }
        guard data.count <= Self.maxPayloadFileSize else { throw RCMInjectionError.payloadTooLarge }
        guard let intermezzoURL = Bundle.main.url(forResource: "intermezzo", withExtension: "bin") else {
            throw RCMInjectionError.missingIntermezzo
        }
        let intermezzo: Data
        do { intermezzo = try Data(contentsOf: intermezzoURL) }
        catch { throw RCMInjectionError.intermezzoReadFailed(error.localizedDescription) }
        let payload = try Self.preparePayload(data, intermezzo: intermezzo)
        try await Task.detached(priority: .userInitiated) {
            try Self.transfer(payload)
        }.value
    }

    static func preparePayload(_ data: Data, intermezzo: Data) throws -> [UInt8] {
        let firstChunkSize = Int(sprayStart - payloadStart)
        // let intermezzoEnd = 680 + intermezzo.count   // 仅用于边界检查，可保留
        // 正确：用户 payload 在 IRAM 的起始偏移
        let payloadOffsetInIRAM = Int(payloadStart - payloadAddress)  // 0xE40
        // intermezzo 在 IRAM 占的大小
        let intermezzoSize = intermezzo.count
        // 需要补的 padding = IRAM 目标 - intermezzo 在 IRAM 的结束位置
        let padToPayload = payloadOffsetInIRAM - intermezzoSize
        guard padToPayload >= 0 else { throw RCMInjectionError.missingIntermezzo }

        var result = [UInt8]()
        result.reserveCapacity(maxLength)
        result.append(contentsOf: withUnsafeBytes(of: UInt32(maxLength).littleEndian, Array.init))
        result.append(contentsOf: repeatElement(0, count: 680 - result.count))
        result.append(contentsOf: intermezzo)
        result.append(contentsOf: repeatElement(0, count: padToPayload))   // ← 改这里
        result.append(contentsOf: data.prefix(firstChunkSize))
        if result.count < Int(sprayStart - payloadAddress) + 680 {  // 注意 spray 也要按 USB 偏移
            // 或者更干净：直接按 IRAM 逻辑继续补
            result.append(contentsOf: repeatElement(0, count: Int(sprayStart - payloadAddress) + 680 - result.count))
        }
        let sprayWord = withUnsafeBytes(of: payloadAddress.littleEndian, Array.init)
        for _ in 0..<Int((sprayEnd - sprayStart) / 4) { result.append(contentsOf: sprayWord) }
        result.append(contentsOf: data.dropFirst(firstChunkSize))
        let padding = (chunkSize - result.count % chunkSize) % chunkSize
        result.append(contentsOf: repeatElement(0, count: padding))
        guard result.count <= maxLength else { throw RCMInjectionError.payloadTooLarge }
        return result
    }

    private static func transfer(_ payload: [UInt8]) throws {
        let host = try RCMHostTransport()
        try host.readDeviceID()

        var currentBuffer = 0
        for offset in stride(from: 0, to: payload.count, by: chunkSize) {
            try host.write(Array(payload[offset..<min(offset + chunkSize, payload.count)]))
            currentBuffer = 1 - currentBuffer
        }
        // The final write must target the high copy buffer at 0x40009000.
        if currentBuffer == 0 {
            try host.write([UInt8](repeating: 0, count: chunkSize))
        }
        try host.trigger()
    }

}
