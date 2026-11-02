import Foundation

public enum DBIError: LocalizedError, Equatable {
    case invalidMagic(Data)
    case invalidHeaderSize(Int)
    case unknownCommand(UInt32)
    case unknownCommandType(UInt32)
    case invalidPayloadSize(Int)
    case fileNameDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMagic(let data):
            "魔数无效：\(data.map { String(format: "%02X", $0) }.joined())"
        case .invalidHeaderSize(let size):
            "头部大小无效：\(size) 字节（预期 \(DBIConstants.headerSize) 字节）"
        case .unknownCommand(let id):
            "未知的 DBI 命令：\(id)"
        case .unknownCommandType(let type):
            "未知的 DBI 命令类型：\(type)"
        case .invalidPayloadSize(let size):
            "数据载荷大小无效：\(size) 字节"
        case .fileNameDecodingFailed:
            "无法将文件名解码为 UTF-8"
        }
    }
}
