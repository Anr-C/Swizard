import Foundation
import CRCMLegacy

/// USB identifiers used to recognize a Switch in RCM mode.
public enum RCMDevice {
    public static let vendorID: UInt16 = 0x0955
    public static let productID: UInt16 = 0x7321
}

/// CrystalRCM's legacy IOKit device and interface session.
final class RCMHostTransport {
    private let session: OpaquePointer

    init() throws {
        var code: Int32 = 0
        guard let opened = crcm_open(RCMDevice.vendorID, RCMDevice.productID, &code) else {
            if code == Int32(bitPattern: 0xe00002c0) {
                throw RCMInjectionError.deviceNotFound
            }
            throw RCMInjectionError.host("打开 RCM 设备/接口失败（\(code)）")
        }
        session = opened
    }

    deinit { crcm_close(session) }

    func readDeviceID() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        var count: UInt32 = 16
        let code = bytes.withUnsafeMutableBufferPointer {
            crcm_read_device_id(session, $0.baseAddress, &count)
        }
        if code == Int32(bitPattern: 0xe0004051) {
            throw RCMInjectionError.deviceIDUnavailable
        }
        guard code == 0 else { throw RCMInjectionError.host("ReadPipeTO 读取设备 ID 失败（\(code)）") }
        guard count == 16, bytes.contains(where: { $0 != 0 }) else {
            throw RCMInjectionError.invalidDeviceID
        }
    }

    func write(_ bytes: [UInt8]) throws {
        let code = bytes.withUnsafeBufferPointer {
            crcm_write_chunk(session, $0.baseAddress, UInt32($0.count))
        }
        guard code == 0 else { throw RCMInjectionError.host("WritePipeTO 发送 payload 失败（\(code)）") }
    }

    func trigger() throws {
        let result = crcm_trigger(session, 0x7000)
        // 和 CrystalRCM 一致：请求意外成功 = 漏洞未触发
        if result == 0 {
            throw RCMInjectionError.unexpectedControlResponse(result)
        }
        // 栈被砸后设备不再响应，超时/掉线是预期成功路径
        let successCodes: Set<Int32> = [
            Int32(bitPattern: 0xe0004051), // kIOUSBTransactionTimeout
            Int32(bitPattern: 0xe00002d6), // kIOReturnTimeout
            Int32(bitPattern: 0xe00002ed), // kIOReturnNotResponding
            Int32(bitPattern: 0xe00002c0), // kIOReturnNoDevice
            Int32(bitPattern: 0xe000404f), // kIOUSBPipeStalled
        ]
        if successCodes.contains(result) {
            return
        }
        throw RCMInjectionError.triggerUnconfirmed("返回错误 \(result)")
    }
}