import Foundation
import XCTest
@testable import RCMTransport

final class RCMInjectorTests: XCTestCase {
    func testPayloadLayoutAndSizeLimit() throws {
        let intermezzo = Data(repeating: 0xa5, count: 124)
        let payload = try FuseeGeleeInjector.preparePayload(Data([0x11, 0x22]), intermezzo: intermezzo)
        XCTAssertEqual(Array(payload[0..<4]), [0x98, 0x02, 0x03, 0x00])
        XCTAssertEqual(Array(payload[680..<804]), [UInt8](repeating: 0xa5, count: 124))
        XCTAssertEqual(Array(payload[0xe40..<0xe42]), [0x11, 0x22])
        XCTAssertEqual(Array(payload[0x4e40..<0x4e44]), [0x00, 0x00, 0x01, 0x40])
        XCTAssertEqual(payload.count % 0x1000, 0)
        XCTAssertThrowsError(try FuseeGeleeInjector.preparePayload(Data(repeating: 0, count: 0x30000), intermezzo: intermezzo))
    }

    func testPayloadBytesAfterStackSprayArePreserved() throws {
        let original = Data((0..<(0x4000 + 3)).map { UInt8($0 & 0xff) })
        let prepared = try FuseeGeleeInjector.preparePayload(original, intermezzo: Data(repeating: 0, count: 124))
        XCTAssertEqual(Array(prepared[0xe40..<0x4e40]), Array(original.prefix(0x4000)))
        XCTAssertEqual(Array(prepared[0x7000..<0x7003]), Array(original.suffix(3)))
    }

    func testLargeFileIsRejectedBeforeReading() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FuseeGeleeInjector.maxPayloadFileSize + 1))
        try handle.close()
        do {
            try await FuseeGeleeInjector().inject(payloadAt: url)
            XCTFail("Expected size rejection")
        } catch RCMInjectionError.payloadTooLarge { }
    }

    func testEmptyAndMissingFilesReportDistinctErrors() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            try await FuseeGeleeInjector().inject(payloadAt: empty)
            XCTFail("Expected empty payload error")
        } catch RCMInjectionError.emptyPayload { }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try await FuseeGeleeInjector().inject(payloadAt: missing)
            XCTFail("Expected file read error")
        } catch RCMInjectionError.payloadReadFailed { }
    }

}
